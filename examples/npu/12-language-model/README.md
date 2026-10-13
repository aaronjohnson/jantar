# 12 · Language model: reading the prompt vs writing each token

**Where it shows up.** On-device assistants, summarising, rewriting text,
local chat. Every language model alternates two phases: **prefill** reads
the whole prompt at once, then **decode** writes the answer one token at a
time.

**Question.** One layer at Llama 3.2 1B's sizes (2,048 features, 32 query
heads sharing 8 key/value heads, an 8,192-wide gated MLP): which phase is
limited by maths, which by moving weights, and do INT8 weights speed up
writing?

**Prediction.** Prefill matrix-bound (like 01), decode weight-bound (like
05): ~120 MB of FP16 weights read per layer per token. INT8 weights halve
the bytes and nearly halve decode time.

**Measured** (one layer; real shapes, random weights; 3 trials, turbo,
spreads ≤ 1%; the 16-layer figures multiply by 16 and leave out the
embedding and output layers):

| phase | wall ms (1 layer) | 16 layers | rate | TOPS |
| --- | ---: | ---: | --- | ---: |
| prefill, 512-token prompt | 8.70 | 139 ms | ~3,700 prompt tokens/s | 7.4 |
| decode, 512 context | 1.61 | 26 ms | ~39 tokens/s | 0.08 |
| decode, 2,048 context | 2.15 | 34 ms | ~29 tokens/s | 0.06 |
| decode, 2,048 context, INT8 weights | 2.41 | 39 ms | ~26 tokens/s | 0.06 |

**What it shows.**
- **The two phases are different kinds of work.** Prefill runs at 7.4
  TOPS; decode at under 0.1, a hundredth, on the same layer. Writing moves
  121.6 MB of weights per layer for each token: at 1.61 ms that's about
  75 GB/s, a large share of the laptop's memory bandwidth. Decode speed is
  a memory question, which is why models for NPUs are small and
  compressed.
- **Longer context costs more** (1.61 → 2.15 ms): attention reads the
  whole key/value cache each token. Part of that here is copying the
  cache in from the host every call; real runtimes keep it on the NPU.
- **The INT8 prediction was wrong.** Weights stored as INT8 made writing
  *slower*: the compiler moved the seven weight-quantized matmuls off the
  DPU and ran them on SHAVE (1.8 of the 2.4 ms). Shipping NPU models use
  weight formats the compiler handles natively (from NNCF); this
  hand-placed quantization isn't one of them. Worth a follow-up.
