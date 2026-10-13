"""Keep the NPU busy from another process, as a second app would.

  background.py EXAMPLE VARIANT TURBO PRIORITY

Builds variant VARIANT (an index) of EXAMPLE, compiles it, prints "ready",
then runs it back to back until stdin closes or it is terminated, and
prints how many inferences it finished and over how long.
"""
import pathlib
import signal
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # -I leaves it out
import numpy as np  # noqa: E402
import openvino as ov  # noqa: E402
import common  # noqa: E402
import harness  # noqa: E402

name, index, turbo, priority = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", sys.argv[4]
_, model, _ = common.sibling(name).variants()[index][:3]
core = ov.Core()
req = core.compile_model(model, "NPU", {"NPU_TURBO": turbo, "MODEL_PRIORITY": priority}).create_infer_request()
feeds = harness.inputs_for(model, np.random.default_rng(1))
req.infer(feeds)

stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
threading.Thread(target=lambda: (sys.stdin.read(), stop.set()), daemon=True).start()
print("ready", flush=True)
n, t0 = 0, time.perf_counter()
while not stop.is_set():
    req.infer(feeds)
    n += 1
print(f"done {n} {time.perf_counter() - t0:.3f}", flush=True)
