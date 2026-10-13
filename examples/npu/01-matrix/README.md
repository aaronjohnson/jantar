# 01 · Matrix work: how fast is the DPU, and does size help?

**Question.** Convolutions and matmuls are what the DPU's multiply-accumulate
arrays are for. How many TOPS do we get, and does a bigger layer use the
hardware better?

**Prediction.** Everything on the DPU; effective TOPS rise with size as
fixed costs (DMA, dispatch) are spread over more work.

**Measured** (NPU 5, Panther Lake; `--seconds 3`; FP16):

| variant | wall ms | NPU ms | TOPS (wall) | TOPS (NPU) |
| --- | ---: | ---: | ---: | ---: |
| 4× conv 3×3, 16 ch, 56×56 | 0.213 | 0.061 | 0.27 | 0.95 |
| 4× conv 3×3, 64 ch | 0.522 | 0.339 | 1.77 | 2.73 |
| 4× conv 3×3, 256 ch | 2.291 | 1.034 | 6.46 | 14.31 |
| matmul 512³ | 0.461 | 0.145 | 0.58 | 1.85 |
| matmul 2048³ | 7.706 | 2.763 | 2.23 | 6.22 |

**What it shows.**
- The prediction held: all DPU, and the DPU's own rate climbs 15× from 16
  to 256 channels. Small layers can't fill the arrays.
- Wall time is two to three times the NPU's time even for the big
  convolution: the host side (submitting, copying FP32 inputs and outputs)
  is a large share of a single small inference.
- Matmuls run at well under half the rate of the equally large
  convolution, and need DMA for the input: a 2048×2048 weight matrix is
  8 MB in FP16, likely more than the tiles' CMX holds at once.

**Watch on jantar** (`n`): compute near 100% while it runs; DMA moderate,
SHAVE quiet.
