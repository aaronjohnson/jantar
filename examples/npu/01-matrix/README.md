# 01 · Matrix work: how fast is the DPU, and does size help?

**Where it shows up.** Vision backbones (photo tagging, YOLO-style
detection, the segmentation behind video-call blur) are stacks of
convolutions, and a language model reading a prompt is mostly big matrix
multiplies: see 10, 12 (prefill) and 13.

**Question.** Convolutions and matmuls are what the DPU's multiply-accumulate
arrays are for. How many TOPS do we get, and does a bigger layer use the
hardware better?

**Prediction.** Everything on the DPU; effective TOPS rise with size as
fixed costs (DMA, dispatch) are spread over more work.

**Measured** (NPU 5, Panther Lake; FP16; 5 trials, turbo, medians; all
spreads ≤ 7%):

| variant | wall ms | NPU ms | TOPS (NPU) |
| --- | ---: | ---: | ---: |
| 4× conv 3×3, 16 ch, 56×56 | 0.121 | 0.027 | 2.1 |
| 4× conv 3×3, 64 ch | 0.255 | 0.148 | 6.3 |
| 4× conv 3×3, 256 ch | 1.474 | 0.952 | 15.5 |
| matmul 512³ | 0.239 | 0.055 | 4.9 |
| matmul 2048³ | 3.038 | 1.413 | 12.2 |

**What it shows.**
- The prediction held: all DPU, and the DPU's rate climbs 7× from 16 to
  256 channels. Small layers can't fill the arrays.
- The host adds a near-constant 0.1 ms or more to every inference
  (submitting, copying FP32 inputs and outputs). For the smallest layer
  that's 80% of the wall time.
- A big matmul gets close to the big convolution's rate (12.2 vs 15.5
  TOPS) but needs DMA: a 2048×2048 weight matrix is 8 MB in FP16, likely
  more than the tiles' CMX holds at once.

**Watch on jantar** (`n`): compute near 100% while it runs; DMA moderate,
SHAVE quiet.
