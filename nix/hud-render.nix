# The Rust NIF (native/hud_render) as a plain cdylib: crates vendored from
# Cargo.lock, no network. The Mix build copies lib/libhud_render.so into
# priv/native and tells Rustler not to run cargo (HUD_RENDER_NIF).
{ lib, rustPlatform }:

let
  root = ../native/hud_render;
in
rustPlatform.buildRustPackage {
  pname = "hud-render";
  version = (lib.importTOML (root + "/Cargo.toml")).package.version;

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/Cargo.toml")
      (root + "/Cargo.lock")
      (root + "/src")
    ];
  };

  cargoLock.lockFile = root + "/Cargo.lock";

  # The NIF needs a running BEAM to do anything; it's tested from ExUnit.
  doCheck = false;
}
