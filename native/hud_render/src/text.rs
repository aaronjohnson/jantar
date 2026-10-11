//! Text with fontdue: rasterised glyphs are cached per (char, size, weight),
//! and blended into the pixmap as coverage masks.

use fontdue::{Font, FontSettings, Metrics};
use std::collections::HashMap;

pub struct Fonts {
    regular: Font,
    bold: Font,
    cache: HashMap<(char, u32, bool), (Metrics, Vec<u8>)>,
}

impl Fonts {
    pub fn load(regular: &str, bold: &str) -> Result<Self, String> {
        let load = |path: &str| -> Result<Font, String> {
            let bytes = std::fs::read(path).map_err(|e| format!("{}: {}", path, e))?;
            Font::from_bytes(bytes, FontSettings::default()).map_err(|e| format!("{}: {}", path, e))
        };
        Ok(Fonts { regular: load(regular)?, bold: load(bold)?, cache: HashMap::new() })
    }

    fn font(&self, bold: bool) -> &Font {
        if bold { &self.bold } else { &self.regular }
    }

    /// Ascent (positive, up) and descent (negative, down) in pixels.
    pub fn line_metrics(&self, size: f32, bold: bool) -> (f32, f32) {
        match self.font(bold).horizontal_line_metrics(size) {
            Some(m) => (m.ascent, m.descent),
            None => (size * 0.76, -size * 0.24),
        }
    }

    pub fn advance(&self, ch: char, size: f32, bold: bool) -> f32 {
        self.font(bold).metrics(ch, size).advance_width
    }

    pub fn width(&self, text: &str, size: f32, bold: bool) -> f32 {
        text.chars().map(|c| self.advance(c, size, bold)).sum()
    }

    /// A glyph's metrics and coverage bitmap (row-major, width x height).
    pub fn glyph(&mut self, ch: char, size: f32, bold: bool) -> &(Metrics, Vec<u8>) {
        // Sizes are cached at 1/64 px resolution.
        let key = (ch, (size * 64.0).round() as u32, bold);
        if !self.cache.contains_key(&key) {
            let g = self.font(bold).rasterize(ch, size);
            self.cache.insert(key, g);
        }
        &self.cache[&key]
    }
}
