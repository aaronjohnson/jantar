//! The framebuffer (or a file standing in for it), written as XRGB8888
//! (bytes B, G, R, X), and only in bands of rows that changed since the last
//! frame, like hud's Framebuffer.show(). Bands are written with pwrite(), not
//! through a memory mapping: writing through the device tells the DRM driver
//! what changed, and with panel self refresh (Intel PSR) the panel otherwise
//! keeps showing the first frame. Plus KDSETMODE and the VT ioctls.

use std::fs::{File, OpenOptions};
use std::os::unix::fs::FileExt;
use std::os::unix::io::AsRawFd;
use tiny_skia::Pixmap;

/// Rows per band when comparing with the previous frame.
const BAND_ROWS: usize = 16;

pub struct Fb {
    file: File,
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
        let size = file.metadata().map_err(|e| format!("{}: {}", path, e))?.len() as usize;
        if size != 0 && size < len {
            return Err(format!("{}: {} bytes, smaller than {} rows of {}", path, size, height, stride));
        }
        Ok(Fb { file, width, height, stride: stride as usize, prev: None })
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
                // A failed write leaves this band to be retried next frame.
                if self.file.write_all_at(&frame[off..end], off as u64).is_err() {
                    self.prev = None;
                    return written;
                }
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

/// VT_SETMODE on a tty: process mode with `signal` as both the release and
/// the acquire signal (Some), or back to automatic switching (None).
///
/// In automatic mode the kernel ignores every switch away from a VT in
/// KD_GRAPHICS (vt_ioctl.c, change_console), so Ctrl+Alt+F1 would do nothing.
/// In process mode it asks the owning process instead, with the signal, and
/// waits for VT_RELDISP. If that process is gone, the next switch resets the
/// VT to text and automatic mode.
pub fn vt_process(tty: &str, signal: Option<i32>) -> Result<(), String> {
    #[repr(C)]
    struct VtMode {
        mode: libc::c_char,
        waitv: libc::c_char,
        relsig: libc::c_short,
        acqsig: libc::c_short,
        frsig: libc::c_short,
    }
    const VT_SETMODE: libc::c_ulong = 0x5602;
    let file = OpenOptions::new().read(true).write(true).open(tty).map_err(|e| format!("{}: {}", tty, e))?;
    let sig = signal.unwrap_or(0) as libc::c_short;
    let mode = VtMode { mode: if signal.is_some() { 1 } else { 0 }, waitv: 0, relsig: sig, acqsig: sig, frsig: 0 };
    // SAFETY: an ioctl on an fd we own, pointing at a struct of the kernel's layout.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), VT_SETMODE as _, &mode as *const VtMode) };
    if rc == 0 { Ok(()) } else { Err(format!("VT_SETMODE on {}: {}", tty, std::io::Error::last_os_error())) }
}

/// VT_RELDISP: 1 lets a pending switch away go ahead, 2 (VT_ACKACQ)
/// acknowledges having been switched to.
pub fn vt_reldisp(tty: &str, arg: i32) -> Result<(), String> {
    const VT_RELDISP: libc::c_ulong = 0x5605;
    let file = OpenOptions::new().read(true).write(true).open(tty).map_err(|e| format!("{}: {}", tty, e))?;
    // SAFETY: a plain ioctl on an fd we own, with an integer argument.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), VT_RELDISP as _, arg as libc::c_ulong) };
    if rc == 0 { Ok(()) } else { Err(format!("VT_RELDISP on {}: {}", tty, std::io::Error::last_os_error())) }
}

/// Make the DRM driver show the framebuffer again: FBIOPUT_VSCREENINFO with
/// the current settings and FB_ACTIVATE_FORCE, which runs the driver's
/// set_par and restores the fbdev mode (drm_fb_helper_set_par).
///
/// Needed when switching to our VT straight from a compositor: the display
/// keeps scanning out the compositor's last frame until something restores
/// fbdev, and with our VT in KD_GRAPHICS the console never does (it does when
/// passing through a text VT, which is why going via Ctrl+Alt+F2 worked). It
/// only takes effect while no DRM master holds the display.
pub fn fb_restore(fb: &str) -> Result<(), String> {
    const FBIOGET_VSCREENINFO: libc::c_ulong = 0x4600;
    const FBIOPUT_VSCREENINFO: libc::c_ulong = 0x4601;
    const FB_ACTIVATE_NOW: u32 = 0;
    const FB_ACTIVATE_FORCE: u32 = 128;
    // struct fb_var_screeninfo: 40 u32s; `activate` is the 22nd (8 geometry
    // fields, 4 bitfield structs of 3, nonstd, then activate).
    const ACTIVATE: usize = 21;
    let file = OpenOptions::new().read(true).write(true).open(fb).map_err(|e| format!("{}: {}", fb, e))?;
    let mut var = [0u32; 40];
    // SAFETY: ioctls on an fd we own, with a buffer the size of the kernel's struct.
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), FBIOGET_VSCREENINFO as _, var.as_mut_ptr()) };
    if rc != 0 {
        return Err(format!("FBIOGET_VSCREENINFO on {}: {}", fb, std::io::Error::last_os_error()));
    }
    var[ACTIVATE] = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), FBIOPUT_VSCREENINFO as _, var.as_ptr()) };
    if rc == 0 { Ok(()) } else { Err(format!("FBIOPUT_VSCREENINFO on {}: {}", fb, std::io::Error::last_os_error())) }
}

/// Keys one at a time and unechoed (raw = true), or back to the usual line
/// editing with echo (false), on a tty, for the dashboard's keyboard.
pub fn tty_raw(tty: &str, raw: bool) -> Result<(), String> {
    let file = OpenOptions::new().read(true).write(true).open(tty).map_err(|e| format!("{}: {}", tty, e))?;
    let fd = file.as_raw_fd();
    // SAFETY: termios is plain data; tcgetattr fills it before we use it.
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd, &mut t) } != 0 {
        return Err(format!("tcgetattr on {}: {}", tty, std::io::Error::last_os_error()));
    }
    if raw {
        // No ISIG: Ctrl+C on the dashboard must not send SIGINT to the VM
        // (the BEAM's break handler).
        t.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG);
        t.c_cc[libc::VMIN] = 1;
        t.c_cc[libc::VTIME] = 0;
    } else {
        t.c_lflag |= libc::ICANON | libc::ECHO | libc::ISIG;
    }
    if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &t) } == 0 {
        Ok(())
    } else {
        Err(format!("tcsetattr on {}: {}", tty, std::io::Error::last_os_error()))
    }
}
