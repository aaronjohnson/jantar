"""Object detection: a YOLO-style network on a 640-pixel image."""
import numpy as np
import openvino.opset13 as op
from blocks import Net
from common import model

TITLE = "Object detection: a YOLO-style network, SiLU vs mish"
REAL_WORLD = "cameras, photo search, robots, counting things in video"
QUESTION = """YOLO detectors find and label objects in one pass: a
convolutional backbone, then detection heads at three scales. YOLOv5 and
v8 use SiLU (swish) activations; YOLOv4 used mish. On this NPU, 02-fusion
found swish free and mish expensive: does that carry over to a whole
detector? And how fast is a frame at 640 and 320 pixels?"""
PREDICTION = """SiLU fuses into every convolution; mish adds a SHAVE layer
after each one and costs well over half again. A 640-pixel frame in a few
milliseconds with SiLU; 320 pixels about four times faster."""


def detector(size, act):
    n = Net()
    x = op.parameter([1, 3, size, size], np.float32)
    hw = (size, size)

    def conv(y, cin, cout, hw, k=3, stride=1):
        return n.conv(y, cin, cout, hw, k, stride, act=act)

    def stage(y, c, hw, blocks):  # residual bottlenecks (C2f, simplified)
        for _ in range(blocks):
            z, _ = conv(y, c, c, hw)
            z, _ = conv(z, c, c, hw)
            y = op.add(y, z)
        return y

    y, hw = conv(x, 3, 16, hw, 3, 2)
    feats = []
    for cin, cout, blocks in [(16, 32, 1), (32, 64, 2), (64, 128, 2), (128, 256, 1)]:
        y, hw = conv(y, cin, cout, hw, 3, 2)
        y = stage(y, cout, hw, blocks)
        if cout >= 64:
            feats.append((y, cout, hw))  # strides 8, 16, 32
    outs = []
    for f, c, fhw in feats:  # a head per scale: 64 box values + 80 classes
        h, _ = conv(f, c, 64, fhw)
        h, _ = conv(h, 64, 64, fhw)
        h, _ = n.conv(h, 64, 144, fhw, 1, act=None)
        outs.append(h)
    return model(outs, [x], f"yolo{size}{act}"), n.flops


def variants():
    out = []
    for size, act in [(640, "silu"), (640, "mish"), (320, "silu")]:
        m, f = detector(size, act)
        out.append((f"YOLO-style, {size}px, {act}", m, f))
    return out
