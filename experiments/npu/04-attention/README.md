# 04 · Attention: a transformer block, as the sequence grows

**Where it shows up.** Language models (the sequence is the prompt, or the
context so far), Whisper transcription (1,500 audio tokens) and vision
transformers (image patches). See 11, 12 and 14 for attention inside whole
models.

**Question.** Attention is matmuls with a softmax in the middle; the scores
and their softmax grow with the square of the sequence. Does time shift
from the DPU toward SHAVE as sequences get longer?

**Prediction.** Short sequences: mostly DPU (the 768×768 projections). Long:
the seq×seq part takes over, SHAVE's share grows.

**Measured** (12 heads, 768 features, FP16; 5 trials, turbo, medians; all
spreads ≤ 1%):

| tokens | wall ms | NPU ms | DPU µs | SHAVE µs | DMA µs | SHAVE share |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 128 | 0.218 | 0.218 | 141 | 72 | 5 | 33% |
| 512 | 0.747 | 0.641 | 324 | 297 | 20 | 46% |
| 1024 | 1.517 | 2.397 | 1639 | 713 | 45 | 30% |

**What it shows.**
- The compiler recognised the pattern and replaced Q·Kᵀ, scale, softmax
  and ·V with one fused **ScaledDotProductAttention** layer on SHAVE;
  only the four projections stayed separate DPU matmuls.
- SHAVE's share rose from 128 to 512 tokens, then fell at 1024: the
  prediction holds only part of the way. At 1024 the DPU time jumps five-
  fold for twice the tokens, more than the projections alone explain;
  possibly the attention is tiled differently once the scores no longer
  fit in CMX.
- At 1024 tokens the engine times add up to more than the wall time:
  DPU and SHAVE layers overlap, so the per-layer sum overstates the
  NPU's busy time.

**Open.** Which part of the 1024-token DPU time is attention rather than the
projections? Profile the projections alone at 1024 tokens to separate them.
