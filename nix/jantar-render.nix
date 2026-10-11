# The Rust NIF (native/jantar_render) as a plain cdylib: crates vendored from
# Cargo.lock, no network. The Mix build copies lib/libjantar_render.so into
# priv/native and tells Rustler not to run cargo (JANTAR_RENDER_NIF).
{ lib, rustPlatform }:

let
  root = ../native/jantar_render;
in
rustPlatform.buildRustPackage {
  pname = "jantar-render";
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
