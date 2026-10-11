//! Reading the display list built by Jantar.Render.DisplayList (see its
//! moduledoc for the format). A tiny little-endian byte cursor; any short or
//! malformed input is an error, never a panic.

pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

pub type R<T> = Result<T, String>;

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Reader { data, pos: 0 }
    }

    pub fn done(&self) -> bool {
        self.pos >= self.data.len()
    }

    fn take(&mut self, n: usize) -> R<&'a [u8]> {
        if self.pos + n > self.data.len() {
            return Err(format!("display list truncated at byte {}", self.pos));
        }
        let s = &self.data[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    pub fn u8(&mut self) -> R<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn u16(&mut self) -> R<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    pub fn u32(&mut self) -> R<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn f32(&mut self) -> R<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn str(&mut self, len: usize) -> R<&'a str> {
        std::str::from_utf8(self.take(len)?).map_err(|e| e.to_string())
    }

    /// The header: "HUD1", width, height.
    pub fn header(&mut self) -> R<(u32, u32)> {
        if self.take(4)? != b"HUD1" {
            return Err("not a display list (bad magic)".into());
        }
        let (w, h) = (self.u32()?, self.u32()?);
        if w == 0 || h == 0 || w > 16384 || h > 16384 {
            return Err(format!("bad frame size {}x{}", w, h));
        }
        Ok((w, h))
    }
}

/// One part of a TEXT run.
pub struct Part<'a> {
    pub text: &'a str,
    pub size: f32,
    pub bold: bool,
    pub rgb: u32,
}
