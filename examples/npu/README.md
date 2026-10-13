# NPU examples

A library of small, single-purpose workloads for learning how the Intel NPU
(here: NPU 5 in a Panther Lake Core Ultra) runs different kinds of work.
Each example asks one question, writes down a prediction first, then
measures: per layer, which engine ran it and for how long.

- **DPU**: the matrix engine (multiply-accumulate arrays in the NCE tiles)
- **SHAVE**: vector DSPs, for maths the DPU can't do
- **DMA**: moving tensors between system RAM and the tiles' CMX SRAM

See jantar's NPU screen (`n`) for how they fit together; the dials there
show each run live.

## The examples

| | question | what we found |
| --- | --- | --- |
| [01-matrix](01-matrix) | How fast is the DPU, and does size help? | 1 → 14 TOPS from 16 to 256 channels; host time ≈ NPU time |
| [02-fusion](02-fusion) | Which activations fuse into the convolution? | almost all, even GELU and swish; mish and ELU cost 2× the conv |
| [03-vector](03-vector) | Where do softmax, norms, reshuffles run? | maths on SHAVE; adds, reductions, transposes on the DPU |
| [04-attention](04-attention) | Does attention shift to SHAVE as sequences grow? | fused into one SHAVE layer; share peaks at 512 tokens |
| [05-data-movement](05-data-movement) | When does data, not maths, set the pace? | big adds are DMA-bound; depthwise convs 50× less efficient |
| [06-precision](06-precision) | How much faster is INT8? | not at all here; open question |

## Method

1. **Question**: one thing to find out.
2. **Prediction**: written before running, in the example's `example.py`.
3. **Run**: `run.py NAME --save` profiles each variant and saves
   `NAME/result.json` (OpenVINO version included).
4. **Write up**: `NAME/README.md`: the numbers, what held, what didn't,
   what's still open. Wrong predictions are the useful ones.

## Running

```sh
nix run ~/src/jantar#npu-example -- list
nix run ~/src/jantar#npu-example -- 02-fusion [--seconds 10] [--json]
```

`--seconds` sets how long each variant runs (longer shows better on the
dials); `--json` prints JSON lines for jantar instead of a report.

`--save` writes into the example's folder, so run it from a checkout:
`. ./env.sh && $NPU_PY -I run.py NAME --save` (in `examples/npu`).

Numbers vary run to run by a few percent, and with OpenVINO and firmware
versions; the saved `result.json` records the version.

## Adding an example

A folder `NN-name/` with `example.py` defining `TITLE`, `QUESTION`,
`PREDICTION` and `variants()`, returning `[(label, ov.Model, flops or None)]`
(`common.py` has helpers), and a `README.md` once measured.
