"""Pure matrix work: convolutions and a matrix multiply, nothing else."""
import openvino.opset13 as op
import numpy as np
from common import conv, conv_flops, model, weights

TITLE = "Matrix work: how fast is the DPU, and does size help?"
QUESTION = """Convolutions and matmuls are what the DPU's multiply-accumulate
arrays are for. How many TOPS do we actually get, and does a bigger layer
use the hardware better than a small one?"""
PREDICTION = """Everything runs on the DPU. Small layers waste time on fixed
costs (DMA in and out, dispatch), so effective TOPS rise with channel
count and level off as the arrays fill."""


def stack(c, hw=56, depth=4):
    x = op.parameter([1, c, hw, hw], np.float32)
    y = x
    for _ in range(depth):
        y = conv(y, c, c)
    return model(y, [x], f"conv{c}"), depth * conv_flops(c, c, 3, hw, hw)


def matmul(n):
    a = op.parameter([1, n, n], np.float32)
    return model(op.matmul(a, weights(n, n), False, False), [a], f"matmul{n}"), 2 * n**3


def variants():
    out = []
    for c in (16, 64, 256):
        m, f = stack(c)
        out.append((f"4x conv3x3, {c} ch, 56x56", m, f))
    for n in (512, 2048):
        m, f = matmul(n)
        out.append((f"matmul {n}x{n}x{n}", m, f))
    return out
