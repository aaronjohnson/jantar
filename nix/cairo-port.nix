# The cairo renderer (c/cairo_port), a standalone program the release starts
# as an Erlang Port. Also used by the NixOS service to put the console back
# into text mode after the dashboard stops (`cairo_port --kd-mode text`).
{
  lib,
  stdenv,
  pkg-config,
  cairo,
  freetype,
}:

stdenv.mkDerivation {
  pname = "cairo-port";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../c/cairo_port;
    fileset = lib.fileset.unions [
      ../c/cairo_port/Makefile
      ../c/cairo_port/cairo_port.c
    ];
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    cairo
    freetype
  ];

  installPhase = ''
    install -Dm755 cairo_port $out/bin/cairo_port
  '';
}
