# 06 · Precision: FP16 against INT8

**Where it shows up.** What actually ships on NPUs: video-effect models
run in INT8, and NPU language models usually store weights as INT4 or
INT8. 12 tries INT8 weights on a language-model layer, with a surprise.

**Question.** The NPU runs float models in FP16. INT8 halves the bytes and
uses integer arrays. How much faster is the same work in INT8?

**Prediction.** About twice as fast on large convolutions; little gain on
small ones.

**Measured** (4× conv 3×3, 56×56; INT8 via FakeQuantize on activations and
weights, per-tensor; 5 trials, turbo, medians; all spreads ≤ 4%):

| variant | wall ms | NPU ms | of which convs | TOPS (NPU) |
| --- | ---: | ---: | ---: | ---: |
| 64 ch, FP16 | 0.210 | 0.146 | 146 µs | 6.3 |
| 64 ch, INT8 | 0.186 | 0.104 | 72 µs (+32 quantizing) | 8.9 |
| 256 ch, FP16 | 1.492 | 0.958 | 958 µs | 15.5 |
| 256 ch, INT8 | 1.032 | 0.773 | 656 µs (+117 quantizing) | 19.1 |

**What it shows.**
- The convolutions themselves are 2.0× faster in INT8 at 64 channels and
  1.46× at 256: the prediction had the sizes backwards.
- Quantizing the FP32 input is a layer of its own (32 and 117 µs), which
  eats part of the gain: 1.4× and 1.24× overall.
- A first, single-run measurement said INT8 was *slower*, and the next
  said faster: the NPU's clock was moving between runs (950 to 2050 MHz).
  Holding it at maximum (turbo) and taking medians of five fresh trials
  settled it. This experiment is why the harness now does both.

**Open.**
- Per-channel weight quantization and symmetric ranges, as real
  quantized models use.
- A model quantized by NNCF, OpenVINO's quantization tool.
- Feed INT8 inputs directly to skip the quantizing layer.
