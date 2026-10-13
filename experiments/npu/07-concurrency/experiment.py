"""Concurrency: several requests in flight, and two apps sharing the NPU."""
import collections
import pathlib
import statistics
import subprocess
import sys
import time

import openvino as ov
from common import sibling
import harness

TITLE = "Concurrency: requests in flight, and apps sharing the NPU"
REAL_WORLD = "a video call: blur, noise suppression and captions at once; indexing in the background"
QUESTION = """Real use is rarely one request at a time. An app keeps several
inferences in flight so the host prepares the next while the NPU runs the
current one; and several apps share the NPU at once (blur during a call
while a language model answers). How much does keeping requests in flight
gain, and what happens to one app's latency when another loads the NPU?
Does priority protect it?"""
PREDICTION = """In flight: the blur model, whose wall time was mostly host
work, gains most (throughput up to ~3x); the big convolution, NPU-bound,
gains little. Sharing: the blur's latency rises with a language model
prefilling in another process, since the NPU runs one job at a time, and
HIGH priority for the blur claws much of that back."""

SEG = sibling("10-video-blur")
CONV = sibling("01-matrix")
LLM = ("12-language-model", 0)   # prefill, 512 tokens: a long, heavy job


def variants():
    seg, seg_f = SEG.segmenter(256, 256)
    conv, conv_f = CONV.stack(256)
    return [
        ("blur, 1 in flight", seg, seg_f, {"inflight": 1}),
        ("blur, 2 in flight", seg, seg_f, {"inflight": 2}),
        ("blur, 4 in flight", seg, seg_f, {"inflight": 4}),
        ("conv 256 ch, 1 in flight", conv, conv_f, {"inflight": 1}),
        ("conv 256 ch, 4 in flight", conv, conv_f, {"inflight": 4}),
        ("blur + LLM in another app", seg, seg_f, {"inflight": 1, "background": LLM}),
        ("blur HIGH + LLM LOW", seg, seg_f, {"inflight": 1, "background": LLM,
                                             "priority": "HIGH", "bg_priority": "LOW"}),
    ]


def start_background(name, index, turbo, priority):
    """Another app: a separate process running an experiment's variant back to back."""
    here = pathlib.Path(__file__).resolve().parent.parent
    p = subprocess.Popen([sys.executable, "-I", str(here / "background.py"), name, str(index),
                          "1" if turbo else "0", priority],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    if p.stdout.readline().strip() != "ready":
        p.kill()
        raise RuntimeError("the background app didn't start")
    return p


def stop_background(p):
    """Stop the other app; its inferences per second while it ran."""
    p.stdin.close()
    out = p.stdout.read().split()
    p.wait(timeout=30)
    return int(out[1]) / float(out[2]) if len(out) == 3 else 0.0


def trial(core, model, seconds, feeds, run, s):
    bg = None
    if "background" in s:
        bg = start_background(*s["background"], run.turbo, s.get("bg_priority", "MEDIUM"))
    try:
        t0 = time.perf_counter()
        compiled = core.compile_model(model, run.device, run.compile_config(
            MODEL_PRIORITY=s.get("priority", "MEDIUM")))
        compile_ms = (time.perf_counter() - t0) * 1e3

        n = s["inflight"]
        queue = ov.AsyncInferQueue(compiled, n)
        latencies = []
        queue.set_callback(lambda req, started: latencies.append(time.perf_counter() - started))
        for _ in range(2 * n):
            queue.start_async(feeds, time.perf_counter())  # warm up
        queue.wait_all()
        latencies.clear()

        a = time.perf_counter()
        end = a + seconds
        window = run.energy.window()
        while True:
            queue.start_async(feeds, time.perf_counter())  # waits while all n are busy
            now = time.perf_counter()
            waiting = window.tick(len(latencies), now >= end)
            if now >= end and len(latencies) >= 20 and (not waiting or now >= end + harness.ENERGY_GRACE):
                break
        queue.wait_all()
        elapsed = time.perf_counter() - a
        mhz = harness.npu_mhz()
    finally:
        bg_rate = stop_background(bg) if bg else None

    by_engine, rows = collections.Counter(), harness.profile(queue[0])
    for _, _, engine, us in rows:
        by_engine[engine] += us
    extra = {"in_flight": n, **window.result()}
    if bg_rate is not None:
        extra["other_app_per_s"] = round(bg_rate, 1)
    return {
        "compile_ms": round(compile_ms, 1),
        # Latency: from handing a request over to its result, including any
        # wait for a free slot on the NPU.
        "latency_ms": statistics.median(latencies) * 1e3,
        "p90_ms": sorted(latencies)[int(len(latencies) * 0.9)] * 1e3,
        "inferences": len(latencies),
        # Throughput: what all requests in flight finished, per second.
        "per_second": len(latencies) / elapsed,
        "npu_mhz": mhz,
        "engines_us": by_engine,
        "device_ms": sum(by_engine.values()) / 1e3,
        "rows": rows,
        "extra": extra,
    }
