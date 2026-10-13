# 05 · Data movement: when the NPU waits on memory

**Question.** Every tensor travels RAM → CMX → RAM through DMA. An add does
one operation per number moved; a convolution hundreds. When does data,
not arithmetic, set the pace?

**Prediction.** The add scales with size at a fixed bandwidth, mostly host
copying; a depthwise convolution behaves like the add, not like a full
convolution.

**Measured:**

| variant | wall ms | NPU ms | engines (µs) | TOPS (NPU) |
| --- | ---: | ---: | --- | ---: |
| add, 64K numbers | 0.39 | 0.15 | DPU 115, SHAVE 19, DMA 18 | – |
| add, 1M numbers | 1.83 | 0.48 | SHAVE 216, DMA 171, DPU 97 | – |
| add, 8M numbers | 9.48 | 2.90 | DMA 1166, SHAVE 1028, DPU 710 | – |
| depthwise 3×3, 128 ch, 112² | 1.78 | 0.50 | DPU 389, DMA 106 | 0.06 |
| full 3×3, 128 ch, 112² | 3.28 | 1.25 | DPU 1142, DMA 106 | 2.96 |

**What it shows.**
- The 8M add moves 96 MB (two FP32 inputs, one output) in 9.5 ms: about
  10 GB/s as the program sees it, and only 2.9 ms of that is the NPU.
  For memory-bound work the host's copies dominate.
- As the add grows, DMA overtakes the other engines: the work is moving
  numbers, not doing sums.
- Depthwise vs full: 128 times fewer operations, yet 40% of the NPU
  time (0.50 vs 1.25 ms): 50× lower efficiency (0.06 vs 2.96 TOPS). Depthwise layers
  (MobileNet and friends) are cheap in FLOPs but don't fill the DPU.
