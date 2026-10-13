"""FP16 against INT8 on the same layers."""
import numpy as np
import openvino.opset13 as op
from common import conv_flops, model, rng

TITLE = "Precision: FP16 against INT8"
REAL_WORLD = "what ships: INT8 video-effect models, INT4/INT8 language-model weights"
QUESTION = """The NPU runs float models in FP16. Quantized models (INT8
weights and activations) halve the bytes to move and use the DPU's
integer arrays. How much faster is the same work in INT8?"""
PREDICTION = """INT8 roughly doubles the DPU's rate on large convolutions and
cuts DMA time; small layers gain little, being bound by fixed costs."""


def fq(x, lo, hi):
    lo, hi = op.constant(np.float32(lo)), op.constant(np.float32(hi))
    return op.fake_quantize(x, lo, hi, lo, hi, 256)


def stack(c, hw, int8, depth=4):
    x = op.parameter([1, c, hw, hw], np.float32)
    y = x
    for _ in range(depth):
        w = op.constant(rng.standard_normal((c, c, 3, 3)).astype(np.float32) * 0.05)
        if int8:
            y, w = fq(y, -4.0, 4.0), fq(w, -0.2, 0.2)
        y = op.convolution(y, w, [1, 1], [1, 1], [1, 1], [1, 1])
    return model(y, [x], f"conv{c}{'q' if int8 else ''}"), depth * conv_flops(c, c, 3, hw, hw)


def variants():
    out = []
    for c in (64, 256):
        for int8 in (False, True):
            m, f = stack(c, 56, int8)
            out.append((f"4x conv, {c} ch, {'INT8' if int8 else 'FP16'}", m, f))
    return out
