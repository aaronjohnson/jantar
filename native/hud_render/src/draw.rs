//! Rasterising a display list with tiny-skia (anti-aliased paths) and the
//! glyph cache in `text`. Every op maps to one or a few tiny-skia calls.

use crate::display_list::{Part, Reader, R};
use crate::text::Fonts;
use std::f32::consts::PI;
use tiny_skia::{
    Color, FillRule, LineCap, Paint, Path, PathBuilder, Pixmap, Rect, Stroke, Transform,
};

/// Draw a whole display list into a new pixmap.
pub fn render(list: &[u8], fonts: &mut Fonts) -> R<Pixmap> {
    let mut r = Reader::new(list);
    let (w, h) = r.header()?;
    let mut pm = Pixmap::new(w, h).ok_or("can't allocate pixmap")?;

    while !r.done() {
        match r.u8()? {
            0x01 => pm.fill(color(r.u32()?)),
            0x02 => {
                for _ in 0..r.u32()? {
                    let (x, y, w, h, c) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                    if let Some(rect) = Rect::from_xywh(x, y, w, h) {
                        pm.fill_rect(rect, &paint(c), Transform::identity(), None);
                    }
                }
            }
            0x03 => {
                let (x0, y0, x1, y1, width, c) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                stroke(&mut pm, line_path(&[(x0, y0), (x1, y1)]), width, c);
            }
            0x04 => {
                for _ in 0..r.u32()? {
                    let (cx, cy, rad, c) = (r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                    if let Some(p) = PathBuilder::from_circle(cx, cy, rad.max(0.01)) {
                        fill(&mut pm, &p, c);
                    }
                }
            }
            0x05 => {
                let (cx, cy, rad, width, c) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                if let Some(p) = PathBuilder::from_circle(cx, cy, rad.max(0.01)) {
                    stroke(&mut pm, Some(p), width, c);
                }
            }
            0x06 => {
                let (cx, cy, rad, a0, a1, width, c) =
                    (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                stroke(&mut pm, line_path(&arc_points(cx, cy, rad, a0, a1)), width, c);
            }
            0x07 => {
                let (x0, y0, x1, y1, rad, c) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                if let Some(p) = rounded_rect(x0, y0, x1, y1, rad) {
                    fill(&mut pm, &p, c);
                }
            }
            0x08 => text_run(&mut pm, &mut r, fonts)?,
            0x09 => {
                let (width, c, n) = (r.f32()?, r.u32()?, r.u32()?);
                let mut pts = Vec::with_capacity(n as usize);
                for _ in 0..n {
                    pts.push((r.f32()?, r.f32()?));
                }
                stroke(&mut pm, line_path(&pts), width, c);
            }
            0x0A => {
                let (width, n) = (r.f32()?, r.u32()?);
                for _ in 0..n {
                    let (x0, y0, x1, y1, c) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.u32()?);
                    stroke(&mut pm, line_path(&[(x0, y0), (x1, y1)]), width, c);
                }
            }
            op => return Err(format!("unknown op 0x{:02x}", op)),
        }
    }
    Ok(pm)
}

// ------------------------------------------------------------------ shapes

fn color(rgb: u32) -> Color {
    Color::from_rgba8((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8, 255)
}

fn paint(rgb: u32) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(color(rgb));
    p.anti_alias = true;
    p
}

fn fill(pm: &mut Pixmap, path: &Path, rgb: u32) {
    pm.fill_path(path, &paint(rgb), FillRule::Winding, Transform::identity(), None);
}

fn stroke(pm: &mut Pixmap, path: Option<Path>, width: f32, rgb: u32) {
    if let Some(path) = path {
        let s = Stroke { width: width.max(0.1), line_cap: LineCap::Butt, ..Stroke::default() };
        pm.stroke_path(&path, &paint(rgb), &s, Transform::identity(), None);
    }
}

fn line_path(points: &[(f32, f32)]) -> Option<Path> {
    let mut pb = PathBuilder::new();
    let (first, rest) = points.split_first()?;
    pb.move_to(first.0, first.1);
    for p in rest {
        pb.line_to(p.0, p.1);
    }
    pb.finish()
}

/// Points along an arc, about one every 2 px (tiny-skia has no arc command).
fn arc_points(cx: f32, cy: f32, r: f32, a0: f32, a1: f32) -> Vec<(f32, f32)> {
    let n = (((a1 - a0).abs() * r / 2.0).ceil() as usize).clamp(2, 4096);
    (0..=n)
        .map(|k| {
            let a = a0 + (a1 - a0) * k as f32 / n as f32;
            (cx + r * a.cos(), cy + r * a.sin())
        })
        .collect()
}

fn rounded_rect(x0: f32, y0: f32, x1: f32, y1: f32, r: f32) -> Option<Path> {
    let r = r.min((x1 - x0) / 2.0).min((y1 - y0) / 2.0).max(0.0);
    let mut pts = Vec::new();
    // Corners clockwise from top right, as quarter arcs.
    for (cx, cy, a0) in [(x1 - r, y0 + r, -PI / 2.0), (x1 - r, y1 - r, 0.0), (x0 + r, y1 - r, PI / 2.0), (x0 + r, y0 + r, PI)] {
        pts.extend(arc_points(cx, cy, r, a0, a0 + PI / 2.0));
    }
    let mut pb = PathBuilder::new();
    let (first, rest) = pts.split_first()?;
    pb.move_to(first.0, first.1);
    for p in rest {
        pb.line_to(p.0, p.1);
    }
    pb.close();
    pb.finish()
}

// ------------------------------------------------------------------ text

fn text_run(pm: &mut Pixmap, r: &mut Reader, fonts: &mut Fonts) -> R<()> {
    let (x, y, halign, valign, n) = (r.f32()?, r.f32()?, r.u8()?, r.u8()?, r.u8()?);
    let mut parts = Vec::with_capacity(n as usize);
    for _ in 0..n {
        let (size, bold, rgb) = (r.f32()?, r.u8()? != 0, r.u32()?);
        let len = r.u16()? as usize;
        parts.push(Part { text: r.str(len)?, size, bold, rgb });
    }
    if parts.is_empty() {
        return Ok(());
    }

    // Place the run as a whole: its width for halign, the biggest part's
    // ascent/descent for valign.
    let width: f32 = parts.iter().map(|p| fonts.width(p.text, p.size, p.bold)).sum();
    let big = parts.iter().max_by(|a, b| a.size.total_cmp(&b.size)).unwrap();
    let (ascent, descent) = fonts.line_metrics(big.size, big.bold);
    let mut pen = match halign {
        1 => x - width / 2.0,
        2 => x - width,
        _ => x,
    };
    let baseline = match valign {
        1 => y + (ascent + descent) / 2.0,
        2 => y + descent,
        _ => y + ascent,
    };

    for p in &parts {
        for ch in p.text.chars() {
            let advance = fonts.advance(ch, p.size, p.bold);
            let (m, coverage) = fonts.glyph(ch, p.size, p.bold);
            let gx = (pen + m.xmin as f32).round() as i32;
            let gy = (baseline - m.ymin as f32 - m.height as f32).round() as i32;
            blend_mask(pm, gx, gy, m.width, m.height, coverage, p.rgb);
            pen += advance;
        }
    }
    Ok(())
}

/// Blend a coverage mask in one colour onto the pixmap (opaque, so plain
/// linear blending of the premultiplied bytes is exact).
fn blend_mask(pm: &mut Pixmap, x0: i32, y0: i32, w: usize, h: usize, cov: &[u8], rgb: u32) {
    let (pw, ph) = (pm.width() as i32, pm.height() as i32);
    let src = [(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8];
    let data = pm.data_mut();
    for row in 0..h as i32 {
        let y = y0 + row;
        if y < 0 || y >= ph {
            continue;
        }
        for col in 0..w as i32 {
            let x = x0 + col;
            if x < 0 || x >= pw {
                continue;
            }
            let a = cov[(row as usize) * w + col as usize] as u32;
            if a == 0 {
                continue;
            }
            let i = ((y * pw + x) * 4) as usize;
            for k in 0..3 {
                let d = data[i + k] as u32;
                data[i + k] = ((src[k] as u32 * a + d * (255 - a) + 127) / 255) as u8;
            }
            data[i + 3] = 255;
        }
    }
}
