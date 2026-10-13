"""Shared harness for the NPU examples: compile each variant of an example on
the NPU, run it long enough for jantar's dials to see it, and profile one
inference per layer (which engine ran it: DPU = matrix, Shave = vector,
DMA = moving data).

An example is a module with TITLE, QUESTION, PREDICTION and variants(),
which returns [(label, ov.Model, flops or None)]. See README.md.

Output is either a readable report or, with --json, one JSON object per
line on stdout, for jantar:
  {"event": "start", "example": ..., "title": ..., "variants": [...]}
  {"event": "variant", "label": ..., "phase": "compile" | "run"}
  {"event": "result", "label": ..., ...}     one per variant
  {"event": "done", "example": ...}
"""
import collections
import json
import statistics
import sys
import time

import numpy as np
import openvino as ov

ENGINES = ("DPU", "Shave", "DMA")


def emit(obj):
    print(json.dumps(obj), flush=True)


def inputs_for(model, rng):
    feeds = {}
    for i, p in enumerate(model.inputs):
        shape = tuple(p.get_partial_shape().to_shape())
        feeds[i] = rng.standard_normal(shape).astype(np.float32)
    return feeds


def profile(req):
    """Per-layer rows of one inference: (name, type, engine, µs)."""
    rows = []
    for p in req.profiling_info:
        if p.status != p.Status.EXECUTED:
            continue
        rows.append((p.node_name, p.node_type, p.exec_type, p.real_time.total_seconds() * 1e6))
    return rows


def run_variant(core, label, model, flops, seconds, rng):
    t0 = time.perf_counter()
    compiled = core.compile_model(model, "NPU", {"PERF_COUNT": True})
    compile_ms = (time.perf_counter() - t0) * 1e3
    req = compiled.create_infer_request()
    feeds = inputs_for(model, rng)
    for _ in range(5):
        req.infer(feeds)  # warm up

    # Latency: many single inferences, back to back, for `seconds`.
    times = []
    end = time.perf_counter() + seconds
    while time.perf_counter() < end or len(times) < 20:
        a = time.perf_counter()
        req.infer(feeds)
        times.append(time.perf_counter() - a)

    rows = profile(req)
    by_engine = collections.Counter()
    for _, _, engine, us in rows:
        by_engine[engine] += us
    total = sum(by_engine.values()) or 1.0
    median_ms = statistics.median(times) * 1e3

    return {
        "label": label,
        "compile_ms": round(compile_ms, 1),
        "latency_ms": round(median_ms, 3),
        "p90_ms": round(sorted(times)[int(len(times) * 0.9)] * 1e3, 3),
        "inferences": len(times),
        "per_second": round(len(times) / sum(times), 1),
        "engines_us": {k: round(v, 1) for k, v in by_engine.most_common()},
        "engines_share": {k: round(v / total, 3) for k, v in by_engine.most_common()},
        # Engine time: the per-layer profile added up, for one inference.
        # Layers on different engines can overlap, so this can exceed the
        # latency; where it's less, the rest is the host: submitting,
        # copying inputs and outputs, waiting for the fence.
        "device_ms": round(total / 1e3, 3),
        "gflop": round(flops / 1e9, 3) if flops else None,
        # Effective rates (FP16 unless the model is quantized), not peaks:
        # over the whole inference, and over the NPU's engine time only.
        "tops": round(flops / (median_ms / 1e3) / 1e12, 2) if flops else None,
        "device_tops": round(flops / (total / 1e6) / 1e12, 2) if flops else None,
        "layers": [
            {"name": n, "type": t, "engine": e, "us": round(us, 1)} for n, t, e, us in rows
        ],
    }


def report(example, results):
    print(f"\n{example.TITLE}\n")
    print("question:  " + " ".join(example.QUESTION.split()))
    print("predicted: " + " ".join(example.PREDICTION.split()))
    print(f"\n{'variant':30} {'wall ms':>8} {'NPU ms':>7} {'/s':>7} {'TOPS':>6} {'NPU':>6}   engine time (one inference)")
    for r in results:
        split = "  ".join(f"{k} {v:.0f}µs" for k, v in r["engines_us"].items())
        tops = f"{r['tops']:.2f}" if r["tops"] is not None else ""
        dtops = f"{r['device_tops']:.2f}" if r["device_tops"] is not None else ""
        print(f"{r['label'][:30]:30} {r['latency_ms']:8.3f} {r['device_ms']:7.3f} {r['per_second']:7.0f} "
              f"{tops:>6} {dtops:>6}   {split}")
    print("\nwall = one inference as the program sees it. NPU = the per-layer engine"
          "\ntimes added up; engines can overlap, so it can exceed wall. TOPS over"
          "\nwall time, then over NPU time.")
    print("\nlayers off the DPU (first variant that has any):")
    for r in results:
        off = [l for l in r["layers"] if l["engine"] not in ("DPU",)]
        if off:
            print(f"  {r['label']}:")
            for l in off:
                print(f"    {l['type'][:22]:22} {l['engine']:8} {l['us']:8.1f} µs")
            break


def run(example, name, seconds, as_json, save=None):
    core = ov.Core()
    if "NPU" not in core.available_devices:
        sys.exit("no NPU: OpenVINO sees " + ", ".join(core.available_devices))
    rng = np.random.default_rng(0)
    variants = example.variants()
    if as_json:
        emit({"event": "start", "example": name, "title": example.TITLE,
              "variants": [v[0] for v in variants]})
    results = []
    for label, model, flops in variants:
        if as_json:
            emit({"event": "variant", "label": label, "phase": "run"})
        r = run_variant(core, label, model, flops, seconds, rng)
        results.append(r)
        if as_json:
            emit({"event": "result", **r})
    if as_json:
        emit({"event": "done", "example": name})
    else:
        report(example, results)
    if save:
        with open(save, "w") as f:
            json.dump({"example": name, "title": example.TITLE,
                       "openvino": ov.get_version(), "seconds_per_variant": seconds,
                       "results": results}, f, indent=1)
            f.write("\n")
    return results
