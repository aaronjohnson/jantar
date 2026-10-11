"""A phased NPU workload for watching jantar's NPU dials (GPU · NPU; `g`
then `2` on the dashboard shows the whole run in its 5-minute window).

  LD_LIBRARY_PATH=$(nix build nixpkgs#level-zero --no-link --print-out-paths)/lib:/run/opengl-driver/lib \\
    nix shell --impure --expr 'with import (builtins.getFlake "nixpkgs") {}; python3.withPackages (p: [ p.openvino p.numpy ])' \\
    -c python3 -I tools/npu-load.py [seconds per phase, default 25]

Phases, measured on the Panther Lake NPU (OpenVINO PERF_COUNT for the
engine split):

  matrix flat out   six 3x3 convolutions, DPU only     compute ~100%, SHAVE 0
  matrix ~45%       the same with 0.5 ms gaps          compute ~46%
  vector heavy      softmax, MVN, exp, sin on SHAVE    SHAVE trace up, more DMA
  matrix ~5%        10 ms gaps                         compute ~6.5%
  idle              the counters close, the NPU suspends
"""
import sys, time
import numpy as np
import openvino as ov
import openvino.opset13 as op

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 25
rng = np.random.default_rng(0)

def matrix():
    x = op.parameter([1, 64, 56, 56], np.float32)
    y = x
    for _ in range(6):
        w = op.constant(rng.standard_normal((64, 64, 3, 3)).astype(np.float32) * 0.05)
        y = op.relu(op.convolution(y, w, [1, 1], [1, 1], [1, 1], [1, 1]))  # ReLU fuses into the DPU
    return ov.Model([y], [x], "matrix")

def vector():
    x = op.parameter([1, 64, 56, 56], np.float32)
    y = x
    for _ in range(6):
        y = op.softmax(y, 1)
        y = op.mvn(y, op.constant([2, 3]), True, 1e-5, "inside_sqrt")
        y = op.sin(op.exp(op.multiply(y, op.constant(np.float32(0.1)))))
    return ov.Model([y], [x], "vector")

core = ov.Core()
cfg = {"NPU_COMPILER_TYPE": "DRIVER"}
reqs = {m.get_friendly_name(): core.compile_model(m, "NPU", cfg).create_infer_request()
        for m in (matrix(), vector())}
img = rng.standard_normal((1, 64, 56, 56)).astype(np.float32)

phases = [("matrix flat out", "matrix", 0.0), ("matrix ~45%", "matrix", 0.0005),
          ("vector / SHAVE heavy", "vector", 0.0), ("matrix ~5%", "matrix", 0.01)]
for name, model, gap in phases:
    print(time.strftime("%T"), "start:", name, flush=True)
    end, n = time.time() + seconds, 0
    while time.time() < end:
        reqs[model].infer({0: img})
        n += 1
        if gap:
            time.sleep(gap)
    print(time.strftime("%T"), f"  {n / seconds:.0f} inf/s", flush=True)
print(time.strftime("%T"), "idle: the NPU should suspend", flush=True)
