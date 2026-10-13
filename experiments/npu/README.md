# NPU experiments

A library of small, single-purpose workloads for learning how the Intel NPU
(here: NPU 5 in a Panther Lake Core Ultra) runs different kinds of work.
Each experiment asks one question, writes down a prediction first, then
measures: per layer, which engine ran it and for how long.

- **DPU**: the matrix engine (multiply-accumulate arrays in the NCE tiles)
- **SHAVE**: vector DSPs, for maths the DPU can't do
- **DMA**: moving tensors between system RAM and the tiles' CMX SRAM

See jantar's NPU screen (`n`) for how they fit together; the dials there
show each run live.

## The lab: one mechanism each

| | question | shows up in | what we found |
| --- | --- | --- | --- |
| [01-matrix](01-matrix) | How fast is the DPU, and does size help? | vision backbones, a language model reading its prompt | 2 → 15.5 TOPS from 16 to 256 channels; the host adds ≥ 0.1 ms each time |
| [02-fusion](02-fusion) | Which activations fuse into the convolution? | every network: GELU, SiLU, ReLU, mish | almost all, even GELU and swish; mish and ELU triple the time |
| [03-vector](03-vector) | Where do softmax, norms, reshuffles run? | every transformer's softmax and norms | maths on SHAVE; adds, reductions, transposes on the DPU |
| [04-attention](04-attention) | Does attention shift to SHAVE as sequences grow? | language models, Whisper, vision transformers | fused into one SHAVE layer; its share peaks at 512 tokens |
| [05-data-movement](05-data-movement) | When does data, not maths, set the pace? | a language model writing; MobileNet; upscaling | big adds are DMA-bound; depthwise convs 50× less efficient |
| [06-precision](06-precision) | How much faster is INT8? | what ships: INT8 video effects, INT4/8 LLM weights | convs 1.5–2×; quantizing the input eats part of it |
| [07-concurrency](07-concurrency) | Requests in flight, and apps sharing the NPU? | a video call's effects at once; background indexing | 2 in flight ≈ 1.8×; another app's job makes blur wait 16×; HIGH priority fixes it |

## Workloads: real models, real shapes

The layers of real models at their real sizes, with random weights (speed
depends on shapes and operations, not on the weights' values; accuracy
isn't measured). Built from [blocks.py](blocks.py).

| | workload | where it runs | what we found |
| --- | --- | --- | --- |
| [10-video-blur](10-video-blur) | MobileNetV2 person segmentation | video-call blur, auto-framing | 0.23 ms a frame: under 1% of a 30 fps budget |
| [11-speech-to-text](11-speech-to-text) | Whisper's encoder, 30 s of audio | live captions, transcripts | 7 ms (tiny): 4,300× faster than real time; 40% is attention |
| [12-language-model](12-language-model) | a Llama 3.2 1B layer: prefill vs decode | assistants, summarising | prompt at 7.4 TOPS, writing at 0.08 (~39 tokens/s, ~75 GB/s of weights); INT8 weights slower |
| [13-object-detection](13-object-detection) | YOLO-style detector, SiLU vs mish | cameras, photo search | 640 frames/s at 640 px; mish costs 35% |
| [14-search-embeddings](14-search-embeddings) | MiniLM sentence embeddings, batched | semantic search, recall | ~1,800 sentences/s; batching doubles it, flat past 8 |

Each experiment's README opens with where it shows up; its `experiment.py` has the
one-line version (`REAL_WORLD`), which jantar's NPU screen shows for the
picked experiment.

**A caution for whole networks.** The "NPU ms" column adds up per-layer
times, but layers overlap across the engines and the NPU's three tiles, so
for whole networks it can be several times the wall time (0.94 against
0.23 ms for the 256×144 segmenter). Wall time is the real latency there;
for a single layer, the per-layer time is the NPU's own.

## Method

1. **Question**: one thing to find out.
2. **Prediction**: written before running, in the experiment's `experiment.py`.
3. **Run**: `run.py NAME --trials 5 --save`. Each variant runs in several
   trials, each compiled afresh, taken in turn round the variants; the
   report gives medians and flags any result whose spread is over 10% as
   UNSETTLED.
4. **Write up**: `NAME/README.md`: the numbers, what held, what didn't,
   what's still open. Wrong predictions are the useful ones.

**Hold the clock still.** The NPU's clock follows load (950 to 2050 MHz
measured), so the same layers took up to 66% longer from one run to the
next. The harness turns on `NPU_TURBO`, which holds it at the maximum;
spreads fell to 1–7%. `--no-turbo` measures the moving clock instead,
which is how applications run by default.

## Running

```sh
nix run ~/src/jantar#npu-experiment -- list
nix run ~/src/jantar#npu-experiment -- 02-fusion [--trials 5] [--seconds 2] [--no-turbo] [--json]
```

`--seconds` sets how long each trial runs (longer shows better on the
dials); `--json` prints JSON lines for jantar instead of a report.

`--save` writes into the experiment's folder, so run it from a checkout:
`. ./env.sh && $NPU_PY -I run.py NAME --save` (in `experiments/npu`).

Numbers vary with OpenVINO and firmware versions; the saved `result.json`
records the version, the trials and whether turbo was on.

## Adding an experiment

A folder `NN-name/` with `experiment.py` defining `TITLE`, `REAL_WORLD` (where
it shows up, one line), `QUESTION`, `PREDICTION` and `variants()`, returning `[(label, ov.Model, flops or None)]`
(`common.py` has helpers), and a `README.md` once measured.
