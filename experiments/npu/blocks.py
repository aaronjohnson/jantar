"""Building blocks for the workload experiments (10-14): the layers real
models are made of, at their real shapes, with random weights. Speed depends
on shapes and operations, not on what the weights are, so timings carry
over to the real models (accuracy doesn't, and isn't measured here).

A Net collects the FLOPs of what it builds (2 per multiply-add), so each
experiment can report effective TOPS.
"""
import numpy as np
import openvino.opset13 as op
from common import rng


def const(*shape, scale=0.02):
    return op.constant(rng.standard_normal(shape).astype(np.float32) * scale)


def scalar(v):
    return op.constant(np.float32(v))


def shape_of(*dims):
    return op.constant(np.array(dims, dtype=np.int64))


class Net:
    def __init__(self):
        self.flops = 0

    # ---------------------------------------------------------------- dense

    def linear(self, x, tokens, din, dout, bias=True):
        """x: [..., tokens, din] -> [..., tokens, dout]."""
        self.flops += 2 * tokens * din * dout
        y = op.matmul(x, const(din, dout), False, False)
        return op.add(y, const(dout)) if bias else y

    def layer_norm(self, x, d):
        y = op.mvn(x, op.constant([-1]), True, 1e-5, "inside_sqrt")
        return op.add(op.multiply(y, const(d, scale=1.0)), const(d))

    def rms_norm(self, x, d):
        """Llama's norm: x / sqrt(mean(x^2) + eps) * w."""
        ms = op.reduce_mean(op.multiply(x, x), op.constant([-1]), True)
        y = op.divide(x, op.sqrt(op.add(ms, scalar(1e-5))))
        return op.multiply(y, const(d, scale=1.0))

    def attention(self, q, k, v, batch, tq, tk, heads, dh, kv_heads=None, causal=False):
        """q: [batch, tq, heads*dh]; k, v: [batch, tk, kv_heads*dh] -> [batch, tq, heads*dh].
        With fewer kv_heads (grouped-query attention, as in Llama), each
        key/value head is shared by heads/kv_heads query heads."""
        kv_heads = kv_heads or heads

        def split(t, n, length):  # [b, len, n*dh] -> [b, n, len, dh]
            t = op.reshape(t, shape_of(batch, length, n, dh), False)
            return op.transpose(t, op.constant([0, 2, 1, 3]))

        q, k, v = split(q, heads, tq), split(k, kv_heads, tk), split(v, kv_heads, tk)
        if kv_heads != heads:
            g = heads // kv_heads

            def share(t):  # [b, kvh, tk, dh] -> [b, heads, tk, dh]
                t = op.unsqueeze(t, op.constant([2]))
                t = op.broadcast(t, shape_of(batch, kv_heads, g, tk, dh))
                return op.reshape(t, shape_of(batch, heads, tk, dh), False)

            k, v = share(k), share(v)
        scores = op.multiply(op.matmul(q, k, False, True), scalar(1 / np.sqrt(dh)))
        if causal:
            mask = np.triu(np.full((tq, tk), -1e4, np.float32), 1 + tk - tq)
            scores = op.add(scores, op.constant(mask))
        out = op.matmul(op.softmax(scores, 3), v, False, False)
        self.flops += 2 * 2 * batch * heads * tq * tk * dh
        out = op.transpose(out, op.constant([0, 2, 1, 3]))
        return op.reshape(out, shape_of(batch, tq, heads * dh), False)

    def encoder_layer(self, x, batch, tokens, d, heads, mlp):
        """A pre-norm transformer encoder layer (Whisper, BERT-style)."""
        n = batch * tokens
        h = self.layer_norm(x, d)
        q, k, v = (self.linear(h, n, d, d) for _ in range(3))
        a = self.attention(q, k, v, batch, tokens, tokens, heads, d // heads)
        x = op.add(x, self.linear(a, n, d, d))
        h = self.layer_norm(x, d)
        h = self.linear(op.gelu(self.linear(h, n, d, mlp), "erf"), n, mlp, d)
        return op.add(x, h)

    # ---------------------------------------------------------------- convolutional

    def conv(self, x, cin, cout, hw, k=3, stride=1, groups=1, act="relu6"):
        """A 2-D convolution (batch norm folded in, as deployed), then an
        activation. hw: input (h, w); returns (y, output hw)."""
        h, w = hw
        p = k // 2
        oh, ow = (h + 2 * p - k) // stride + 1, (w + 2 * p - k) // stride + 1
        if groups == 1:
            y = op.convolution(x, const(cout, cin, k, k, scale=0.1), [stride] * 2, [p, p], [p, p], [1, 1])
            self.flops += 2 * cin * cout * k * k * oh * ow
        else:  # depthwise
            y = op.group_convolution(x, const(groups, 1, 1, k, k, scale=0.1), [stride] * 2, [p, p], [p, p], [1, 1])
            self.flops += 2 * cin * k * k * oh * ow
        y = op.add(y, const(1, cout, 1, 1))
        return activate(y, act), (oh, ow)


def activate(y, act):
    if act == "relu6":
        return op.clamp(y, 0.0, 6.0)
    if act == "silu":
        return op.multiply(y, op.sigmoid(y))
    if act == "mish":
        return op.mish(y)
    if act is None:
        return y
    raise ValueError(act)
