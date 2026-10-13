"""One self-attention block, the heart of a transformer, at three lengths."""
import numpy as np
import openvino.opset13 as op
from common import model, weights

TITLE = "Attention: a transformer block, as the sequence grows"
QUESTION = """Attention is matmuls (projections, Q times K, the weights times
V) with a softmax in the middle. As the sequence grows, Q times K and the
softmax grow with its square. Does the NPU's time shift from the DPU
toward SHAVE as sequences get longer?"""
PREDICTION = """Short sequences: the four 768x768 projections dominate, nearly
all DPU. Long sequences: the seq x seq scores and their softmax take over,
so SHAVE's share grows."""

D, HEADS = 768, 12


def block(seq):
    hd = D // HEADS
    x = op.parameter([1, seq, D], np.float32)

    def heads(t):  # [1, seq, D] -> [1, HEADS, seq, hd]
        t = op.reshape(t, op.constant([1, seq, HEADS, hd]), False)
        return op.transpose(t, op.constant([0, 2, 1, 3]))

    q = heads(op.matmul(x, weights(D, D), False, False))
    k = heads(op.matmul(x, weights(D, D), False, False))
    v = heads(op.matmul(x, weights(D, D), False, False))
    scores = op.multiply(op.matmul(q, k, False, True), op.constant(np.float32(1 / np.sqrt(hd))))
    attn = op.matmul(op.softmax(scores, 3), v, False, False)
    merged = op.reshape(op.transpose(attn, op.constant([0, 2, 1, 3])), op.constant([1, seq, D]), False)
    y = op.matmul(merged, weights(D, D), False, False)
    flops = 4 * 2 * seq * D * D + 2 * 2 * seq * seq * D
    return model(y, [x], f"attn{seq}"), flops


def variants():
    out = []
    for seq in (128, 512, 1024):
        m, f = block(seq)
        out.append((f"attention, {seq} tokens", m, f))
    return out
