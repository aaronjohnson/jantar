# 02 · Fusion: which activations ride along with the DPU?

**Question.** After a convolution the DPU can transform its output on the way
out, for free. Which activations fuse like that, and which become their
own layer on SHAVE?

**Prediction.** Piecewise ones (ReLU, clamp, leaky ReLU, hard-swish) fuse;
smooth ones built on exp or erf (sigmoid, swish, GELU, tanh, mish) go to
SHAVE.

**Measured** (conv 3×3, 64 ch, 56×56, then the activation; 5 trials, turbo,
medians; all spreads ≤ 7%):

- **Fused, no extra layer, no extra time** (NPU 54–58 µs, the same as no
  activation): ReLU, clamp, leaky ReLU, hard-swish, **sigmoid, swish,
  GELU (erf and tanh forms), tanh, exp**.
- **A separate SHAVE layer**: mish (SHAVE 118 µs) and ELU (116 µs),
  tripling the NPU time to 0.165 ms.

**What it shows.**
- The prediction was wrong, in an interesting way: the DPU's output stage
  handles far more than piecewise functions, including the smooth,
  exp-based ones transformers use (GELU, swish). It likely evaluates them
  by lookup table or approximation; the profile can't tell us which.
- Mish and ELU are a trap on this NPU: each costs over twice the
  convolution itself.
- Lesson for model choice: GELU or swish are free here; mish is not.

(An earlier single run had tanh faster than no activation; with trials and
a steady clock it's the same, so that was noise.)
