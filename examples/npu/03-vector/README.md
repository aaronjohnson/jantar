# 03 · Vector work: softmax, normalisation and friends

**Question.** Transformers and vision models spend real time in operations
that aren't matrix multiplies. Where do they run, and how fast?

**Prediction.** The maths (softmax, MVN, exp, sin) on SHAVE; reshuffles
(transpose, concat) by DMA.

**Measured** (each operation alone; image-like `[1,64,56,56]` or
token-like `[1,512,768]`; 5 trials, turbo, medians):

| operation | NPU µs | ran on |
| --- | ---: | --- |
| softmax over channels (image) | 108 | SHAVE |
| softmax over features (tokens) | 54 | SHAVE 38, DMA 16 |
| layer norm (MVN) | 85 | SHAVE 62, DMA 23 |
| exp | 31 (unsettled, ±19%) | SHAVE 19, DMA 12 |
| sin | 70 | SHAVE 60, DMA 10 |
| sum over space | 36 | DPU 35 |
| transpose | 70 | DPU 42, SHAVE 28 |
| add (elementwise) | 26 | DPU 15, DMA 11 |

**What it shows.**
- Half right: the transcendental maths runs on SHAVE, as predicted.
- Reductions, elementwise adds and even transposes run on the DPU, not
  DMA. The compiler expresses them as DPU operations (a reduction as
  pooling, a transpose as a strided copy), keeping SHAVE for what only
  it can do.
- sin's SHAVE time is three times exp's (60 vs 19 µs): not every
  transcendental is equally cheap on SHAVE.
- Standalone, exp runs on SHAVE; after a convolution it fused into the
  DPU for free (02-fusion). Context decides placement.
