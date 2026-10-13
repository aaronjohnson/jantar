# 02 · Fusion: which activations ride along with the DPU?

**Question.** After a convolution the DPU can transform its output on the way
out, for free. Which activations fuse like that, and which become their
own layer on SHAVE?

**Prediction.** Piecewise ones (ReLU, clamp, leaky ReLU, hard-swish) fuse;
smooth ones built on exp or erf (sigmoid, swish, GELU, tanh, mish) go to
SHAVE.

**Measured** (conv 3×3, 64 ch, 56×56, then the activation):

- **Fused, no extra layer, no extra time** (DPU ~135 µs, the same as no
  activation): ReLU, clamp, leaky ReLU, hard-swish, **sigmoid, swish,
  GELU (erf and tanh forms), tanh, exp**.
- **A separate SHAVE layer**: mish (+261 µs) and ELU (+278 µs), nearly
  tripling the NPU time.

**What it shows.**
- The prediction was wrong, in an interesting way: the DPU's output stage
  handles far more than piecewise functions, including the smooth,
  exp-based ones transformers use (GELU, swish). It likely evaluates them
  by lookup table or approximation; the profile can't tell us which.
- Two common activations, mish and ELU, are a trap on this NPU: each
  costs about twice the convolution itself.
- Lesson for model choice: GELU or swish are free here; mish is not.

**Open.** tanh came out faster (116 µs) than no activation at all; repeat
to see whether that's noise or the compiler choosing a different tiling.
