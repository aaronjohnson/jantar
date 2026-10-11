//! jantar's Rust renderer, loaded into the BEAM as a NIF (Rustler) as
//! `Jantar.Render.Native`.
//!
//! Drawing a frame takes milliseconds to tens of milliseconds, far longer
//! than the ~1 ms a NIF may block a normal scheduler, so every function that
//! draws runs on a dirty CPU scheduler (`schedule = "DirtyCpu"`).
//!
//! State lives in two resources, reference-counted handles that Elixir holds:
//! a Renderer (fonts and glyph cache) and an Fb (the mapped framebuffer).
//! Both are behind a Mutex because a resource is shared, immutable data to
//! Rust, and the BEAM could call in from two processes at once.

mod display_list;
mod draw;
mod fb;
mod text;

use rustler::{Binary, Resource, ResourceArc};
use std::sync::Mutex;
use std::time::Instant;

pub struct Renderer(Mutex<text::Fonts>);
pub struct Framebuffer(Mutex<fb::Fb>);

#[rustler::resource_impl]
impl Resource for Renderer {}

#[rustler::resource_impl]
impl Resource for Framebuffer {}

type NifResult<T> = Result<T, String>;

/// Load the regular and bold fonts.
#[rustler::nif(schedule = "DirtyIo")]
fn new(regular: String, bold: String) -> NifResult<ResourceArc<Renderer>> {
    Ok(ResourceArc::new(Renderer(Mutex::new(text::Fonts::load(&regular, &bold)?))))
}

/// Draw a display list and save it as a PNG. Returns the drawing time in µs.
#[rustler::nif(schedule = "DirtyCpu")]
fn render_png(r: ResourceArc<Renderer>, list: Binary, path: String) -> NifResult<u64> {
    let t = Instant::now();
    let pm = draw::render(list.as_slice(), &mut r.0.lock().unwrap())?;
    let us = t.elapsed().as_micros() as u64;
    pm.save_png(&path).map_err(|e| format!("{}: {}", path, e))?;
    Ok(us)
}

/// Map a framebuffer device (or a file of stride x height bytes).
#[rustler::nif(schedule = "DirtyIo")]
fn open_fb(path: String, width: u32, height: u32, stride: u32) -> NifResult<ResourceArc<Framebuffer>> {
    Ok(ResourceArc::new(Framebuffer(Mutex::new(fb::Fb::open(&path, width, height, stride)?))))
}

/// Draw a display list into the framebuffer. Returns {µs to draw, bands written}.
#[rustler::nif(schedule = "DirtyCpu")]
fn render_fb(r: ResourceArc<Renderer>, f: ResourceArc<Framebuffer>, list: Binary) -> NifResult<(u64, u32)> {
    let t = Instant::now();
    let pm = draw::render(list.as_slice(), &mut r.0.lock().unwrap())?;
    let bands = f.0.lock().unwrap().show(&pm);
    Ok((t.elapsed().as_micros() as u64, bands))
}

/// Make the next render_fb write the whole screen.
#[rustler::nif]
fn invalidate(f: ResourceArc<Framebuffer>) -> rustler::Atom {
    f.0.lock().unwrap().invalidate();
    rustler::types::atom::ok()
}

/// KDSETMODE: graphics (true) or text (false) on a tty such as /dev/tty12.
#[rustler::nif(schedule = "DirtyIo")]
fn kd_mode(tty: String, graphics: bool) -> NifResult<rustler::Atom> {
    fb::kd_mode(&tty, graphics)?;
    Ok(rustler::types::atom::ok())
}

/// VT_SETMODE: process mode with this signal number (> 0), or automatic (0).
#[rustler::nif(schedule = "DirtyIo")]
fn vt_process(tty: String, signal: i32) -> NifResult<rustler::Atom> {
    fb::vt_process(&tty, if signal > 0 { Some(signal) } else { None })?;
    Ok(rustler::types::atom::ok())
}

/// VT_RELDISP: 1 = let the switch away happen, 2 = acknowledge a switch here.
#[rustler::nif(schedule = "DirtyIo")]
fn vt_reldisp(tty: String, arg: i32) -> NifResult<rustler::Atom> {
    fb::vt_reldisp(&tty, arg)?;
    Ok(rustler::types::atom::ok())
}

/// For the crash demo: a Rust panic. Rustler catches it at the NIF boundary
/// and raises an Erlang error in the calling process; the VM carries on.
#[rustler::nif]
fn panic_demo() -> rustler::Atom {
    panic!("deliberate panic from jantar_render");
}

rustler::init!("Elixir.Jantar.Render.Native");
