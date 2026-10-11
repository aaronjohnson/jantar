# beam-hud as an Elixir release: the Gleam core, the Rust NIF and the cairo
# port are separate derivations (see hud-core.nix, hud-render.nix,
# cairo-port.nix), handed to the Mix build through environment variables, so
# no Gleam, cargo or make runs inside mixRelease.
{
  lib,
  beamPackages,
  callPackage,
  makeWrapper,
  dejavu_fonts,
}:

let
  root = ./..;
  version = "0.1.0";

  hudCore = callPackage ./hud-core.nix { inherit (beamPackages) erlang; };
  hudRender = callPackage ./hud-render.nix { };
  cairoPort = callPackage ./cairo-port.nix { };

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/mix.exs")
      (root + "/mix.lock")
      (root + "/config")
      (root + "/lib")
      (root + "/rel")
    ];
  };
in
beamPackages.mixRelease {
  pname = "beam-hud";
  inherit version src;

  # Rustler and its jason, from Hex, by fixed hash.
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "beam-hud-mix-deps";
    inherit version src;
    hash = "sha256-NFHlyM0mBpcGyGoyNarEgTjhVb8nRw6cl5mIH6gF4F0=";
  };

  nativeBuildInputs = [ makeWrapper ];

  env = {
    HUD_CORE_BUILD = "${hudCore}";
    HUD_RENDER_NIF = "${hudRender}/lib/libhud_render.so";
    CAIRO_PORT_BIN = "${cairoPort}/bin/cairo_port";
  };

  # Rustler loads priv/native/hud_render.so; put the prebuilt one there.
  preBuild = ''
    mkdir -p priv/native
    cp $HUD_RENDER_NIF priv/native/hud_render.so
  '';

  # The fonts both renderers draw with.
  postInstall = ''
    wrapProgram $out/bin/beam_hud \
      --set-default BEAM_HUD_FONT_DIR ${dejavu_fonts}/share/fonts/truetype
  '';

  passthru = { inherit hudCore hudRender cairoPort; };

  meta = {
    description = "System dashboard for a Linux console, on the BEAM (Gleam + Elixir, Rust and C renderers)";
    mainProgram = "beam_hud";
    platforms = lib.platforms.linux;
  };
}
