"""When moving data, not maths, sets the pace."""
import numpy as np
import openvino.opset13 as op
from common import conv, conv_flops, model, weights

TITLE = "Data movement: when the NPU waits on memory"
QUESTION = """Every tensor has to come from system RAM into the tiles' CMX
and back, through DMA. An elementwise add does one operation per number
moved; a wide convolution does hundreds. When does the data, rather than
the arithmetic, decide how long a layer takes?"""
PREDICTION = """The add's time grows with its size at a fixed bandwidth (a few
GB/s), and its wall time is mostly host copying. A depthwise convolution
(few operations per number) behaves more like the add than like a full
convolution of the same size."""


def add(n):
    a = op.parameter([1, n], np.float32)
    b = op.parameter([1, n], np.float32)
    return model(op.add(a, b), [a, b], f"add{n}")


def depthwise(c, hw):
    x = op.parameter([1, c, hw, hw], np.float32)
    w = weights(c, 1, 1, 3, 3)
    y = op.group_convolution(x, w, [1, 1], [1, 1], [1, 1], [1, 1])
    return model(y, [x], "dw"), 2 * c * 9 * hw * hw


def full(c, hw):
    x = op.parameter([1, c, hw, hw], np.float32)
    return model(conv(x, c, c), [x], "full"), conv_flops(c, c, 3, hw, hw)


def variants():
    out = [(f"add, {n // 1024}K numbers", add(n), n) for n in (64 * 1024, 1024 * 1024, 8 * 1024 * 1024)]
    m, f = depthwise(128, 112)
    out.append(("depthwise 3x3, 128 ch, 112x112", m, f))
    m, f = full(128, 112)
    out.append(("full 3x3, 128 ch, 112x112", m, f))
    return out
