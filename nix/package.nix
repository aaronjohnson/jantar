# jantar as an Elixir release: the Gleam core, the Rust NIF and the cairo
# port are separate derivations (see jantar-core.nix, jantar-render.nix,
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

  jantarCore = callPackage ./jantar-core.nix { inherit (beamPackages) erlang; };
  jantarRender = callPackage ./jantar-render.nix { };
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
  pname = "jantar";
  inherit version src;

  # Rustler and its jason, from Hex, by fixed hash.
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "jantar-mix-deps";
    inherit version src;
    hash = "sha256-NFHlyM0mBpcGyGoyNarEgTjhVb8nRw6cl5mIH6gF4F0=";
  };

  nativeBuildInputs = [ makeWrapper ];

  env = {
    JANTAR_CORE_BUILD = "${jantarCore}";
    JANTAR_RENDER_NIF = "${jantarRender}/lib/libjantar_render.so";
    CAIRO_PORT_BIN = "${cairoPort}/bin/cairo_port";
  };

  # Rustler loads priv/native/jantar_render.so; put the prebuilt one there.
  preBuild = ''
    mkdir -p priv/native
    cp $JANTAR_RENDER_NIF priv/native/jantar_render.so
  '';

  # The fonts both renderers draw with.
  postInstall = ''
    wrapProgram $out/bin/jantar \
      --set-default JANTAR_FONT_DIR ${dejavu_fonts}/share/fonts/truetype
  '';

  passthru = { inherit jantarCore jantarRender cairoPort; };

  meta = {
    description = "System dashboard for a Linux console, on the BEAM (Gleam + Elixir, Rust and C renderers)";
    mainProgram = "jantar";
    platforms = lib.platforms.linux;
  };
}
