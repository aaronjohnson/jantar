# experiments/npu as a command: Python with OpenVINO, and Level Zero found the
# way NixOS needs (the loader only looks in FHS paths or LD_LIBRARY_PATH).
{ lib, writeShellApplication, python3, level-zero }:

let
  py = python3.withPackages (p: [ p.openvino p.numpy ]);
  experiments = lib.cleanSource ../experiments/npu;
in
writeShellApplication {
  name = "npu-experiment";
  runtimeInputs = [ py ];
  text = ''
    export LD_LIBRARY_PATH=${level-zero}/lib:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    # --save writes into the experiment's folder: only from a checkout.
    exec python3 -I ${experiments}/run.py "$@"
  '';
}
