"""Speech to text: Whisper's audio encoder on 30 seconds of sound."""
import numpy as np
import openvino.opset13 as op
from blocks import Net, const
from common import model

TITLE = "Speech to text: Whisper's encoder on 30 s of audio"
REAL_WORLD = "live captions, meeting transcripts, voice typing"
QUESTION = """Whisper turns 30 s of audio (a log-mel spectrogram) into 1,500
tokens with two 1-D convolutions and a stack of transformer layers; a
decoder then writes the text a token at a time. How long does the encoder
take for 30 s of audio, and where does the time go?"""
PREDICTION = """Tens of milliseconds even for the base model: hundreds of
times faster than real time. At 1,500 tokens, attention (SHAVE) takes a
large share, as 04-attention found at 512 to 1,024 tokens."""


def conv1d(n, x, cin, cout, length, stride):
    n.flops += 2 * cin * cout * 3 * (length // stride)
    y = op.convolution(x, const(cout, cin, 3, scale=0.05), [stride], [1], [1], [1])
    return op.gelu(op.add(y, const(1, cout, 1)), "erf")


def encoder(d, heads, layers, frames=3000):
    n = Net()
    x = op.parameter([1, 80, frames], np.float32)
    y = conv1d(n, x, 80, d, frames, 1)
    y = conv1d(n, y, d, d, frames, 2)
    tokens = frames // 2
    y = op.add(op.transpose(y, op.constant([0, 2, 1])), const(1, tokens, d))  # + positions
    for _ in range(layers):
        y = n.encoder_layer(y, 1, tokens, d, heads, 4 * d)
    return model(n.layer_norm(y, d), [x], f"whisper{d}"), n.flops


def variants():
    out = []
    for name, d, heads, layers in [("tiny", 384, 6, 4), ("base", 512, 8, 6)]:
        m, f = encoder(d, heads, layers)
        out.append((f"Whisper {name} encoder, 30 s", m, f))
    return out
