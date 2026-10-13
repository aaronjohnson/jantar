"""Shared harness for the NPU examples: compile each variant of an example on
the NPU, run it long enough for jantar's dials to see it, and profile one
inference per layer (which engine ran it: DPU = matrix, Shave = vector,
DMA = moving data).

An example is a module with TITLE, QUESTION, PREDICTION and variants(),
which returns [(label, ov.Model, flops or None)]. See README.md.

Output is either a readable report or, with --json, one JSON object per
line on stdout, for jantar:
  {"event": "start", "example": ..., "title": ..., "variants": [...],
   "trials": n, "steps": variants x trials}
  {"event": "variant", "label": "... (t/n)", "phase": "run"}   each step
  {"event": "result", "label": ..., ...}     one per variant, at the end
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


NPU_MHZ = "/sys/class/accel/accel0/device/npu_current_frequency_mhz"
# A spread (max - min, over the median) above this marks a result unsettled.
UNSTABLE = 0.10


def npu_mhz():
    try:
        with open(NPU_MHZ) as f:
            return int(f.read())
    except OSError:
        return None


def trial(core, model, seconds, feeds, turbo=True):
    """One trial: compile afresh, warm up, run back to back for `seconds`.

    Turbo holds the NPU's clock at its maximum. Without it the clock
    follows load (measured: 950 to 2050 MHz between trials of the same
    layers), and the same work took up to 66% longer from one trial to the
    next; with it, 1%."""
    t0 = time.perf_counter()
    compiled = core.compile_model(model, "NPU", {"PERF_COUNT": True, "NPU_TURBO": turbo})
    compile_ms = (time.perf_counter() - t0) * 1e3
    req = compiled.create_infer_request()
    for _ in range(5):
        req.infer(feeds)  # warm up

    # The NPU's clock moves with load (power management), so sample it
    # through the trial, between inferences, every 20 ms or so.
    times, clocks = [], []
    end = time.perf_counter() + seconds
    next_clock = 0.0
    while time.perf_counter() < end or len(times) < 20:
        a = time.perf_counter()
        req.infer(feeds)
        b = time.perf_counter()
        times.append(b - a)
        if b >= next_clock:
            clocks.append(npu_mhz())
            next_clock = b + 0.02
    clocks = [m for m in clocks if m]
    mhz = statistics.median(clocks) if clocks else None

    rows = profile(req)
    by_engine = collections.Counter()
    for _, _, engine, us in rows:
        by_engine[engine] += us
    return {
        "compile_ms": round(compile_ms, 1),
        "latency_ms": statistics.median(times) * 1e3,
        "p90_ms": sorted(times)[int(len(times) * 0.9)] * 1e3,
        "inferences": len(times),
        "per_second": len(times) / sum(times),
        "npu_mhz": mhz,
        "engines_us": by_engine,
        # Engine time: the per-layer profile added up, for one inference.
        # Layers on different engines can overlap, so this can exceed the
        # latency; where it's less, the rest is the host: submitting,
        # copying inputs and outputs, waiting for the fence.
        "device_ms": sum(by_engine.values()) / 1e3,
        "rows": rows,
    }


def spread(values):
    """(median, min, max, spread): the spread is (max - min) / median, with
    the highest and lowest left out once there are 5 or more, so one odd
    trial doesn't make a result look unsettled."""
    m = statistics.median(values)
    core = sorted(values)[1:-1] if len(values) >= 5 else values
    return m, min(values), max(values), (max(core) - min(core)) / m if m else 0.0


def summarise(label, flops, trials):
    """A variant's result over its trials: medians, spreads, and the median
    trial's per-layer profile."""
    dev = spread([t["device_ms"] for t in trials])
    lat = spread([t["latency_ms"] for t in trials])
    mid = sorted(trials, key=lambda t: t["device_ms"])[len(trials) // 2]
    total = sum(mid["engines_us"].values()) or 1.0
    return {
        "label": label,
        "trials": len(trials),
        "latency_ms": round(lat[0], 3),
        "latency_range_ms": [round(lat[1], 3), round(lat[2], 3)],
        "latency_spread": round(lat[3], 3),
        "device_ms": round(dev[0], 3),
        "device_range_ms": [round(dev[1], 3), round(dev[2], 3)],
        "device_spread": round(dev[3], 3),
        # The NPU's own time is what the examples are about.
        "stable": dev[3] <= UNSTABLE,
        "per_second": round(statistics.median(t["per_second"] for t in trials), 1),
        "compile_ms": round(statistics.median(t["compile_ms"] for t in trials), 1),
        "npu_mhz": [t["npu_mhz"] for t in trials],
        "engines_us": {k: round(v, 1) for k, v in mid["engines_us"].most_common()},
        "engines_share": {k: round(v / total, 3) for k, v in mid["engines_us"].most_common()},
        "gflop": round(flops / 1e9, 3) if flops else None,
        # Effective rates (FP16 unless the model is quantized), not peaks:
        # over the whole inference, and over the NPU's engine time only.
        "tops": round(flops / (lat[0] / 1e3) / 1e12, 2) if flops else None,
        "device_tops": round(flops / (dev[0] / 1e3) / 1e12, 2) if flops else None,
        "by_trial": [
            {"device_ms": round(t["device_ms"], 3), "latency_ms": round(t["latency_ms"], 3),
             "npu_mhz": t["npu_mhz"], "compile_ms": t["compile_ms"]}
            for t in trials
        ],
        "layers": [
            {"name": n, "type": ty, "engine": e, "us": round(us, 1)} for n, ty, e, us in mid["rows"]
        ],
    }


def report(example, results):
    print(f"\n{example.TITLE}\n")
    print("question:  " + " ".join(example.QUESTION.split()))
    print("predicted: " + " ".join(example.PREDICTION.split()))
    n = results[0]["trials"] if results else 0
    print(f"\n{n} trials per variant, each compiled afresh; medians, with the NPU time's range.")
    print(f"\n{'variant':30} {'wall ms':>8} {'NPU ms':>7} {'range':>15} {'spread':>7} {'TOPS':>6} {'NPU':>6}   engines (median trial)")
    for r in results:
        split = "  ".join(f"{k} {v:.0f}µs" for k, v in r["engines_us"].items())
        tops = f"{r['tops']:.2f}" if r["tops"] is not None else ""
        dtops = f"{r['device_tops']:.2f}" if r["device_tops"] is not None else ""
        lo, hi = r["device_range_ms"]
        flag = "" if r["stable"] else "  UNSETTLED"
        print(f"{r['label'][:30]:30} {r['latency_ms']:8.3f} {r['device_ms']:7.3f} {lo:7.3f}–{hi:<7.3f} "
              f"{r['device_spread'] * 100:6.0f}% {tops:>6} {dtops:>6}   {split}{flag}")
    print("\nwall = one inference as the program sees it. NPU = the per-layer engine"
          "\ntimes added up: layers overlap across engines and the NPU's tiles, so for"
          "\nwhole networks it can far exceed wall (trust wall there); for a single"
          "\nlayer it's the NPU's own time. TOPS over wall, then over NPU. spread ="
          f"\n(max - min) / median of the NPU time, less the extremes from 5 trials;"
          f"\nover {UNSTABLE:.0%} is UNSETTLED.")
    clocks = sorted({m for r in results for m in r["npu_mhz"] if m})
    if clocks:
        print("NPU clock seen during trials: " + ", ".join(f"{m} MHz" for m in clocks))
    print("\nlayers off the DPU (first variant that has any):")
    for r in results:
        off = [l for l in r["layers"] if l["engine"] not in ("DPU",)]
        if off:
            print(f"  {r['label']}:")
            for l in off:
                print(f"    {l['type'][:22]:22} {l['engine']:8} {l['us']:8.1f} µs")
            break


def run(example, name, seconds, as_json, save=None, trials=3, turbo=True):
    core = ov.Core()
    if "NPU" not in core.available_devices:
        sys.exit("no NPU: OpenVINO sees " + ", ".join(core.available_devices))
    rng = np.random.default_rng(0)
    variants = example.variants()
    feeds = [inputs_for(model, rng) for _, model, _ in variants]
    labels = [v[0] for v in variants]
    if as_json:
        emit({"event": "start", "example": name, "title": example.TITLE,
              "variants": labels, "trials": trials, "steps": trials * len(variants)})

    # Trials go round the variants, so slow drift (clocks, temperature)
    # spreads over all of them instead of favouring the first.
    done = [[] for _ in variants]
    for t in range(trials):
        for i, (label, model, _) in enumerate(variants):
            if as_json:
                emit({"event": "variant", "label": f"{label} ({t + 1}/{trials})", "phase": "run"})
            done[i].append(trial(core, model, seconds, feeds[i], turbo))

    results = [summarise(label, flops, done[i]) for i, (label, _, flops) in enumerate(variants)]
    if as_json:
        for r in results:
            emit({"event": "result", **r})
        emit({"event": "done", "example": name})
    else:
        report(example, results)
    if save:
        with open(save, "w") as f:
            json.dump({"example": name, "title": example.TITLE,
                       "openvino": ov.get_version(), "seconds_per_trial": seconds,
                       "trials": trials, "turbo": turbo, "results": results}, f, indent=1)
            f.write("\n")
    return results
