"""Background blur on a video call: person segmentation, every frame."""
import numpy as np
import openvino.opset13 as op
from blocks import Net
from common import model

TITLE = "Video-call blur: segmenting a person, every frame"
REAL_WORLD = "video calls: background blur and replacement, auto-framing"
QUESTION = """Background blur runs a segmentation network on every camera
frame: which pixels are you. These networks (MobileNet and relatives) are
built from depthwise convolutions to keep FLOPs low. How much of a 30 fps
frame budget (33 ms) does it take, and how well do those layers use the
NPU?"""
PREDICTION = """Well under 1 ms a frame at the usual 256-pixel input, so
blur costs the NPU only a few percent of its time. But TOPS will be low:
depthwise layers starve the DPU, as in 05-data-movement."""

# MobileNetV2: (expansion, channels, repeats, stride)
CFG = [(1, 16, 1, 1), (6, 24, 2, 2), (6, 32, 3, 2), (6, 64, 4, 2), (6, 96, 3, 1), (6, 160, 3, 2), (6, 320, 1, 1)]


def segmenter(h, w):
    n = Net()
    x = op.parameter([1, 3, h, w], np.float32)
    y, hw = n.conv(x, 3, 32, (h, w), 3, 2)
    cin = 32
    for t, c, reps, s in CFG:
        for i in range(reps):
            stride = s if i == 0 else 1
            inp, hid = y, cin * t
            if t != 1:
                y, _ = n.conv(y, cin, hid, hw, 1)
            y, hw2 = n.conv(y, hid, hid, hw, 3, stride, groups=hid)
            y, _ = n.conv(y, hid, c, hw2, 1, act=None)
            if stride == 1 and cin == c:
                y = op.add(y, inp)  # inverted residual
            cin, hw = c, hw2
    # A light head: one mask channel at 1/32 resolution, upsampled outside
    # the network (as many deployed blur pipelines do on the GPU).
    y, _ = n.conv(y, cin, 1, hw, 1, act=None)
    return model(op.sigmoid(y), [x], f"seg{h}x{w}"), n.flops


def variants():
    out = []
    for h, w, what in [(144, 256, "landscape 256x144"), (256, 256, "square 256x256"), (512, 512, "high-res 512x512")]:
        m, f = segmenter(h, w)
        out.append((f"MobileNetV2 seg, {what}", m, f))
    return out
