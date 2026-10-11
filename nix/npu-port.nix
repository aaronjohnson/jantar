# The NPU counters program (c/npu_port), which the release starts as an
# Erlang Port to read the NPU's Level Zero metrics.
{
  lib,
  stdenv,
  pkg-config,
  level-zero,
}:

stdenv.mkDerivation {
  pname = "npu-port";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../c/npu_port;
    fileset = lib.fileset.unions [
      ../c/npu_port/Makefile
      ../c/npu_port/npu_port.c
    ];
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ level-zero ];

  installPhase = ''
    install -Dm755 npu_port $out/bin/npu_port
  '';
}
