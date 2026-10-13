# Development only: source to get $NPU_PY (python with OpenVINO) and the
# Level Zero library path, from jantar's pinned nixpkgs.
NP=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ../..)).inputs.nixpkgs.outPath')
NPU_PY=$(nix build --no-link --print-out-paths --impure --expr "with import $NP {}; python3.withPackages (p: [ p.openvino p.numpy ])")/bin/python3
export LD_LIBRARY_PATH=$(nix build --no-link --print-out-paths --impure --expr "with import $NP {}; level-zero")/lib:/run/opengl-driver/lib
