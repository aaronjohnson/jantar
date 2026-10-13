# 03 · Vector work: softmax, normalisation and friends

**Question.** Transformers and vision models spend real time in operations
that aren't matrix multiplies. Where do they run, and how fast?

**Prediction.** The maths (softmax, MVN, exp, sin) on SHAVE; reshuffles
(transpose, concat) by DMA.

**Measured** (each operation alone; image-like `[1,64,56,56]` or
token-like `[1,512,768]`):

| operation | NPU µs | ran on |
| --- | ---: | --- |
| softmax over channels (image) | 238 | SHAVE |
| softmax over features (tokens) | 103 | SHAVE 75, DMA 28 |
| layer norm (MVN) | 216 | SHAVE 151, DMA 65 |
| exp | 65 | SHAVE 49, DMA 16 |
| sin | 161 | SHAVE 136, DMA 25 |
| sum over space | 88 | DPU 84 |
| transpose | 187 | DPU 113, SHAVE 74 |
| add (elementwise) | 82 | DPU 49, DMA 33 |

**What it shows.**
- Half right: the transcendental maths runs on SHAVE, as predicted.
- Reductions, elementwise adds and even transposes run on the DPU, not
  DMA. The compiler expresses them as DPU operations (a reduction as
  pooling, a transpose as a strided copy), keeping SHAVE for what only
  it can do.
- sin costs twice exp: not every transcendental is equally cheap on SHAVE.
- Standalone, exp runs on SHAVE (65 µs); after a convolution it fused
  into the DPU for free (02-fusion). Context decides placement.
