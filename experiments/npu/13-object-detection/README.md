# 13 · Object detection: a YOLO-style network, SiLU vs mish

**Where it shows up.** Security and doorbell cameras, photo search ("find
pictures with a dog"), robots, counting things in video. YOLO detectors find
and label every object in one pass over the image.

**Question.** 02-fusion found swish (SiLU) free and mish expensive after one
convolution. Does that carry over to a whole detector? And how fast is a
frame at 640 and 320 pixels?

**Prediction.** SiLU fuses everywhere; mish adds a SHAVE layer per
convolution and costs well over half again. A 640-pixel frame in a few
milliseconds; 320 pixels about four times faster.

**Measured** (a YOLOv8n-sized backbone with detection heads at three scales,
neck simplified; random weights; 3 trials, turbo, spreads ≤ 2%):

| variant | wall ms | frames/s | TOPS | DPU / SHAVE |
| --- | ---: | ---: | ---: | --- |
| 640 px, SiLU | 1.56 | 640 | 5.3 | 96% / 0% |
| 640 px, mish | 2.11 | 470 | 3.9 | 67% / 31% |
| 320 px, SiLU | 0.37 | 2,540 | 5.6 | 98% / 0% |

**What it shows.**
- The fusion result carries over: with SiLU the whole detector runs on the
  DPU; with mish, SHAVE takes a third of the engine time.
- Mish costs 35% more time, not "well over half": in a whole network the
  DPU work around each activation dilutes the penalty, and some of the
  SHAVE work overlaps the DPU's.
- A quarter of the pixels runs 4.2× faster, as predicted.
- Lesson: an architecture choice made for GPUs (YOLOv4's mish) has a real
  cost on this NPU; later YOLOs' SiLU is free here.
