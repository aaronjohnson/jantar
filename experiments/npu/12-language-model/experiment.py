"""A language model reading a prompt, then writing a token at a time."""
import numpy as np
import openvino.opset13 as op
from blocks import Net, activate, const
from common import model

TITLE = "Language model: reading the prompt vs writing each token"
REAL_WORLD = "on-device assistants, summarising, rewriting text"
QUESTION = """A language model works in two phases. Reading the prompt
(prefill) pushes all its tokens through each layer at once: big matrix
multiplies. Writing (decode) produces one token at a time, and every token
reads all the layer's weights again. One layer at Llama 3.2 1B's sizes:
which phase is limited by maths, which by moving weights, and what do
INT8 weights do for writing?"""
PREDICTION = """Prefill is matrix-bound, like 01-matrix: high TOPS. Decode is
weight-bound, like 05-data-movement: about 120 MB of FP16 weights per layer
per token, so time is set by bandwidth and TOPS collapse. INT8 weights
halve the bytes and nearly halve decode time."""

D, HEADS, KV_HEADS, DH, MLP = 2048, 32, 8, 64, 8192
KV = KV_HEADS * DH


def fq(w, r=0.1):
    lo, hi = op.constant(np.float32(-r)), op.constant(np.float32(r))
    return op.fake_quantize(w, lo, hi, lo, hi, 256)


class Llama(Net):
    def __init__(self, int8=False):
        super().__init__()
        self.int8 = int8

    def linear(self, x, tokens, din, dout, bias=False):
        self.flops += 2 * tokens * din * dout
        w = const(din, dout)
        return op.matmul(x, fq(w) if self.int8 else w, False, False)


def layer(n, x, tq, k, v, tk, causal):
    """One decoder layer (RoPE left out: elementwise, small)."""
    h = n.rms_norm(x, D)
    q = n.linear(h, tq, D, D)
    a = n.attention(q, k, v, 1, tq, tk, HEADS, DH, KV_HEADS, causal)
    x = op.add(x, n.linear(a, tq, D, D))
    h = n.rms_norm(x, D)
    g = activate(n.linear(h, tq, D, MLP), "silu")
    return op.add(x, n.linear(op.multiply(g, n.linear(h, tq, D, MLP)), tq, MLP, D))


def prefill(tokens):
    n = Llama()
    x = op.parameter([1, tokens, D], np.float32)
    h = n.rms_norm(x, D)
    k, v = n.linear(h, tokens, D, KV), n.linear(h, tokens, D, KV)
    return model(layer(n, x, tokens, k, v, tokens, True), [x], f"prefill{tokens}"), n.flops


def decode(context, int8=False):
    n = Llama(int8)
    x = op.parameter([1, 1, D], np.float32)
    k_cache = op.parameter([1, context, KV], np.float32)
    v_cache = op.parameter([1, context, KV], np.float32)
    h = n.rms_norm(x, D)
    k = op.concat([k_cache, n.linear(h, 1, D, KV)], 1)
    v = op.concat([v_cache, n.linear(h, 1, D, KV)], 1)
    y = layer(n, x, 1, k, v, context + 1, False)
    return model(y, [x, k_cache, v_cache], f"decode{context}"), n.flops


def variants():
    out = []
    m, f = prefill(512)
    out.append(("prefill, 512-token prompt", m, f))
    for ctx in (512, 2048):
        m, f = decode(ctx)
        out.append((f"decode 1 token, {ctx} context", m, f))
    m, f = decode(2048, int8=True)
    out.append(("decode, 2048 ctx, INT8 weights", m, f))
    return out
