# 06 · Precision: FP16 against INT8

**Question.** The NPU runs float models in FP16. INT8 halves the bytes and
uses integer arrays. How much faster is the same work in INT8?

**Prediction.** About twice as fast on large convolutions; little gain on
small ones.

**Measured** (4× conv 3×3, 56×56; INT8 via FakeQuantize on activations and
weights, per-tensor):

| variant | wall ms | NPU ms | TOPS (NPU) |
| --- | ---: | ---: | ---: |
| 64 ch, FP16 | 0.46 | 0.26 | 3.63 |
| 64 ch, INT8 | 0.51 | 0.25 | 3.73 |
| 256 ch, FP16 | 2.72 | 1.10 | 13.42 |
| 256 ch, INT8 | 2.60 | 1.56 | 9.47 |

**What it shows.**
- The prediction failed: INT8 was no faster, and slower on the NPU for
  256 channels. Quantizing the FP32 input became its own 300 µs layer,
  and the INT8 convolutions took as long as the FP16 ones.
- So either this NPU's FP16 rate matches its INT8 rate for these shapes,
  or the compiler didn't run these convolutions in INT8. The compiled
  model is an opaque blob, so OpenVINO can't show the precision it chose.

**Open, and next to try.**
- Per-channel weight quantization and symmetric ranges (what real
  quantized models use) instead of one range per tensor.
- A model quantized by NNCF, OpenVINO's quantization tool, rather than
  hand-placed FakeQuantize.
- Feed INT8 or FP16 inputs directly to skip the input quantization layer.
