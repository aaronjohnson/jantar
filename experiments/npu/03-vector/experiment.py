"""Work with no matrix in it: what runs where when the DPU has nothing to do."""
import numpy as np
import openvino.opset13 as op
from common import model

TITLE = "Vector work: softmax, normalisation and friends"
REAL_WORLD = "softmax in every transformer, layer norm in language models and Whisper"
QUESTION = """Transformers and many vision models spend real time in
operations that aren't matrix multiplies: softmax, layer norm, exponentials,
reductions, reshuffles. Where do these run, and how fast compared with
the matrix work in 01-matrix?"""
PREDICTION = """The maths (softmax, MVN, exp, sin) runs on SHAVE, slower per
element than the DPU's matrix work. Pure data reshuffles (transpose,
concat) are done by DMA, or by the DPU as a copy."""

SHAPE = [1, 64, 56, 56]   # an image-like tensor
SEQ = [1, 512, 768]       # a transformer's tokens x features


def one(name, shape, f):
    x = op.parameter(shape, np.float32)
    return (name, model(f(x), [x], name.split()[0]), None)


def variants():
    return [
        one("softmax over channels", SHAPE, lambda x: op.softmax(x, 1)),
        one("softmax over features", SEQ, lambda x: op.softmax(x, 2)),
        one("layer norm (MVN)", SEQ, lambda x: op.mvn(x, op.constant([2]), True, 1e-5, "inside_sqrt")),
        one("exp", SHAPE, op.exp),
        one("sin", SHAPE, op.sin),
        one("sum over space", SHAPE, lambda x: op.reduce_sum(x, op.constant([2, 3]), False)),
        one("transpose", SEQ, lambda x: op.transpose(x, op.constant([0, 2, 1]))),
        one("add (elementwise)", SHAPE, lambda x: op.add(x, x)),
    ]
