# 05 · Data movement: when the NPU waits on memory

**Question.** Every tensor travels RAM → CMX → RAM through DMA. An add does
one operation per number moved; a convolution hundreds. When does data,
not arithmetic, set the pace?

**Prediction.** The add scales with size at a fixed bandwidth, mostly host
copying; a depthwise convolution behaves like the add, not like a full
convolution.

**Measured** (5 trials, turbo, medians; all spreads ≤ 8%):

| variant | wall ms | NPU ms | engines (µs) | TOPS (NPU) |
| --- | ---: | ---: | --- | ---: |
| add, 64K numbers | 0.24 | 0.11 | DPU 80, DMA 16, SHAVE 14 | – |
| add, 1M numbers | 1.08 | 0.33 | DMA 140, SHAVE 121, DPU 64 | – |
| add, 8M numbers | 8.28 | 2.24 | DMA 1001, SHAVE 723, DPU 511 | – |
| depthwise 3×3, 128 ch, 112² | 1.18 | 0.30 | DPU 215, DMA 88 | 0.10 |
| full 3×3, 128 ch, 112² | 1.64 | 0.73 | DPU 640, DMA 89 | 5.07 |

**What it shows.**
- The 8M add moves 96 MB (two FP32 inputs, one output) in 8.3 ms: about
  12 GB/s as the program sees it, and only 2.2 ms of that is the NPU.
  For memory-bound work the host's copies dominate.
- As the add grows, DMA overtakes the other engines: the work is moving
  numbers, not doing sums.
- Depthwise vs full: 128 times fewer operations, yet 40% of the NPU
  time: 50× lower efficiency (0.10 vs 5.07 TOPS). Depthwise layers
  (MobileNet and friends) are cheap in FLOPs but don't fill the DPU.
