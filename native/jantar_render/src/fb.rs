//! The framebuffer (or a file standing in for it): memory-mapped, written as
//! XRGB8888 (bytes B, G, R, X), and only in bands of rows that changed since
//! the last frame, like hud's Framebuffer.show(). Plus KDSETMODE, which tells
//! the console to stop drawing its text over us.

use memmap2::MmapMut;
use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;
use tiny_skia::Pixmap;

/// Rows per band when comparing with the previous frame.
const BAND_ROWS: usize = 16;

pub struct Fb {
    map: MmapMut,
    pub width: u32,
    pub height: u32,
    stride: usize,
    /// The last frame written, in framebuffer layout; None forces a full write.
    prev: Option<Vec<u8>>,
}

impl Fb {
    pub fn open(path: &str, width: u32, height: u32, stride: u32) -> Result<Fb, String> {
        let file = OpenOptions::new().read(true).write(true).open(path).map_err(|e| format!("{}: {}", path, e))?;
        let len = stride as usize * height as usize;
        if stride < width * 4 {
            return Err(format!("stride {} is less than {} pixels x 4 bytes", stride, width));
        }
        // SAFETY: the mapping is only accessed through this struct, and we
        // write within its length. Another process could write the same
        // memory (the console), which is why we ask for KD_GRAPHICS first.
        let map = unsafe { memmap2::MmapOptions::new().len(len).map_mut(&file) }.map_err(|e| format!("mmap {}: {}", path, e))?;
        Ok(Fb { map, width, height, stride: stride as usize, prev: None })
    }

    /// Forget the previous frame, so the next one is written in full (after
    /// switching back to the VT, the screen may show anything).
    pub fn invalidate(&mut self) {
        self.prev = None;
    }

    /// Write a frame; returns the number of bands written.
    pub fn show(&mut self, pm: &Pixmap) -> u32 {
        let (w, h) = (pm.width().min(self.width) as usize, pm.height().min(self.height) as usize);
        let src = pm.data();
        let mut frame = vec![0u8; self.stride * h];
        for y in 0..h {
            let s = &src[y * pm.width() as usize * 4..];
            let d = &mut frame[y * self.stride..];
            for x in 0..w {
                // RGBA (opaque) -> B G R X
                d[x * 4] = s[x * 4 + 2];
                d[x * 4 + 1] = s[x * 4 + 1];
                d[x * 4 + 2] = s[x * 4];
                d[x * 4 + 3] = 0;
            }
        }
        let band = self.stride * BAND_ROWS;
        let mut written = 0;
        for off in (0..frame.len()).step_by(band) {
            let end = (off + band).min(frame.len());
            let changed = match &self.prev {
                Some(p) => p.len() != frame.len() || p[off..end] != frame[off..end],
                None => true,
            };
            if changed {
                self.map[off..end].copy_from_slice(&frame[off..end]);
                written += 1;
            }
        }
        self.prev = Some(frame);
        written
    }
}

/// KDSETMODE on a tty: graphics (the console stops drawing) or text.
pub fn kd_mode(tty: &str, graphics: bool) -> Result<(), String> {
    const KDSETMODE: libc::c_ulong = 0x4B3A;
    let file = OpenOptions::new().read(true).write(true).open(tty).map_err(|e| format!("{}: {}", tty, e))?;
    let mode: libc::c_int = if graphics { 1 } else { 0 };
    // SAFETY: a plain ioctl on an fd we own, with an integer argument.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), KDSETMODE as _, mode) };
    if rc == 0 { Ok(()) } else { Err(format!("KDSETMODE on {}: {}", tty, std::io::Error::last_os_error())) }
}
