"""Which activations fuse into the convolution, and which fall out to SHAVE."""
import numpy as np
import openvino.opset13 as op
from common import conv, conv_flops, model

TITLE = "Fusion: which activations ride along with the DPU?"
QUESTION = """After a convolution, the DPU can apply some functions to its
output on the way out (post-processing), for free. Which activations does
it fuse like that, and which become a separate layer on the SHAVE cores?"""
PREDICTION = """Simple, piecewise ones (ReLU, clamp, leaky ReLU, hard-swish)
fuse. Smooth ones built on exp or erf (sigmoid, swish, GELU, tanh, mish)
need SHAVE, and cost a layer of their own."""

ACTIVATIONS = {
    "none": lambda y: y,
    "relu": op.relu,
    "clamp 0..6": lambda y: op.clamp(y, 0.0, 6.0),
    "leaky relu": lambda y: op.prelu(y, op.constant(np.float32([0.1]))),
    "hswish": op.hswish,
    "sigmoid": op.sigmoid,
    "swish": lambda y: op.multiply(y, op.sigmoid(y)),
    "gelu (erf)": lambda y: op.gelu(y, "erf"),
    "gelu (tanh)": lambda y: op.gelu(y, "tanh"),
    "tanh": op.tanh,
    "mish": op.mish,
    "elu": lambda y: op.elu(y, 1.0),
    "exp": op.exp,
}


def variants():
    out = []
    for name, act in ACTIVATIONS.items():
        x = op.parameter([1, 64, 56, 56], np.float32)
        y = act(conv(x, 64, 64))
        out.append((f"conv + {name}", model(y, [x], name), conv_flops(64, 64, 3, 56, 56)))
    return out
