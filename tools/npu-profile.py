"""Profile one inference of a small mixed model on the NPU, per layer: which
engine ran each (DPU = matrix, Shave = vector, DMA) and for how long.

  LD_LIBRARY_PATH=$(nix build nixpkgs#level-zero --no-link --print-out-paths)/lib:/run/opengl-driver/lib \\
    nix shell --impure --expr 'with import (builtins.getFlake "nixpkgs") {}; python3.withPackages (p: [ p.openvino p.numpy ])' \\
    -c python3 -I tools/npu-profile.py

On the Panther Lake NPU, activations (ReLU, swish, GELU) fuse into the
convolutions on the DPU; only softmax ran on SHAVE.
"""
import collections
import numpy as np
import openvino as ov
import openvino.opset13 as op

rng = np.random.default_rng(0)

def conv(x, cin, cout, stride=1, groups=1):
    if groups == 1:
        w = op.constant(rng.standard_normal((cout, cin, 3, 3)).astype(np.float32) * 0.1)
        return op.convolution(x, w, [stride, stride], [1, 1], [1, 1], [1, 1])
    w = op.constant(rng.standard_normal((groups, cout // groups, cin // groups, 3, 3)).astype(np.float32) * 0.1)
    return op.group_convolution(x, w, [stride, stride], [1, 1], [1, 1], [1, 1])

x = op.parameter([1, 3, 224, 224], np.float32, name="image")
y = op.relu(conv(x, 3, 32, 2))                       # matrix work
y = conv(y, 32, 64, 2)
y = op.multiply(y, op.sigmoid(y))                    # swish: vector work
y = conv(y, 64, 64, 1, groups=64)                    # depthwise
y = op.gelu(y, "erf")                                     # vector work
y = conv(y, 64, 128, 2)
y = op.reduce_mean(y, op.constant([2, 3]), False)    # global pool -> [1,128]
w = op.constant(rng.standard_normal((128, 1000)).astype(np.float32) * 0.1)
y = op.matmul(y, w, False, False)                    # matrix work
y = op.softmax(y, 1)                                 # vector work
model = ov.Model([y], [x], "mixed")

core = ov.Core()
print("devices:", core.available_devices)
compiled = core.compile_model(model, "NPU", {"NPU_COMPILER_TYPE": "DRIVER", "PERF_COUNT": True})
req = compiled.create_infer_request()
img = rng.standard_normal((1, 3, 224, 224)).astype(np.float32)
for _ in range(5):
    req.infer({0: img})              # warm up
req.infer({0: img})

rows = [p for p in req.profiling_info if p.status == p.Status.EXECUTED]
total = collections.Counter()
print(f"\n{'layer':42} {'type':18} {'ran on':14} {'µs':>8}")
for p in rows:
    us = p.real_time.total_seconds() * 1e6
    total[p.exec_type] += us
    print(f"{p.node_name[:42]:42} {p.node_type[:18]:18} {p.exec_type[:14]:14} {us:8.1f}")
print("\nby engine:")
for k, v in total.most_common():
    print(f"  {k:16} {v:8.1f} µs")
