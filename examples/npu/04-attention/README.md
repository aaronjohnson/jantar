# 04 · Attention: a transformer block, as the sequence grows

**Question.** Attention is matmuls with a softmax in the middle; the scores
and their softmax grow with the square of the sequence. Does time shift
from the DPU toward SHAVE as sequences get longer?

**Prediction.** Short sequences: mostly DPU (the 768×768 projections). Long:
the seq×seq part takes over, SHAVE's share grows.

**Measured** (12 heads, 768 features, FP16):

| tokens | wall ms | DPU µs | SHAVE µs | DMA µs | SHAVE share |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 128 | 0.36 | 155 | 72 | 5 | 31% |
| 512 | 1.17 | 403 | 309 | 23 | 42% |
| 1024 | 2.05 | 1692 | 733 | 44 | 30% |

**What it shows.**
- The compiler recognised the pattern and replaced Q·Kᵀ, scale, softmax
  and ·V with one fused **ScaledDotProductAttention** layer on SHAVE;
  only the four projections stayed separate DPU matmuls.
- SHAVE's share rose from 128 to 512 tokens, then fell at 1024: the
  prediction holds only part of the way. At 1024 the DPU time jumps
  fourfold for twice the tokens, more than the projections alone
  explain; possibly the attention is tiled differently once the scores
  no longer fit in CMX.
- At 1024 tokens the engine times add up to more than the wall time:
  DPU and SHAVE layers overlap, so the per-layer sum overstates the
  NPU's busy time.

**Open.** Which part of the 1024-token DPU time is attention rather than the
projections? Profile the projections alone at 1024 tokens to separate them.
