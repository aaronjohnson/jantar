# 10 · Video-call blur: segmenting a person, every frame

**Where it shows up.** Background blur and replacement in video calls, and
auto-framing: a small segmentation network decides, for every camera frame,
which pixels are you. On "AI PCs" this is a showcase NPU job, because it
runs all call long.

**Question.** How much of a 30 fps frame budget (33 ms) does segmentation
take, and how well do MobileNet's depthwise layers use the NPU?

**Prediction.** Well under 1 ms a frame at the usual 256-pixel input; low
TOPS, because depthwise layers starve the DPU (05-data-movement).

**Measured** (MobileNetV2 backbone, the architecture of many blur models,
with a one-channel mask head; random weights; 3 trials, turbo, spreads ≤ 1%):

| input | wall ms | of a 30 fps frame | frames/s possible | TOPS |
| --- | ---: | ---: | ---: | ---: |
| 256×144 (landscape) | 0.23 | 0.7% | 4,200 | 1.8 |
| 256×256 | 0.30 | 0.9% | 3,200 | 2.4 |
| 512×512 | 0.99 | 3.0% | 1,000 | 3.0 |

**What it shows.**
- The prediction held: a frame costs under 1% of the frame budget. The NPU
  can blur a call while sleeping most of the time, which is the point of
  doing it there rather than on the GPU.
- TOPS stay low (2–3, against 15 for wide convolutions in 01-matrix):
  MobileNet is cheap in FLOPs, not efficient per FLOP.
- Everything ran on the DPU, depthwise layers included; no SHAVE.

**Watch on jantar.** The NPU wakes, runs in short bursts and sleeps: at
real call rates (30 fps) it's busy under 1% of the time.
