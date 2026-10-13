"""Run an NPU experiment: run.py NAME [--device D] [--tiles N] [--no-turbo] [--cache DIR]
                          [--seconds S] [--trials N] [--json] [--save]

  NAME        an experiment folder (01-matrix), or `list` for the catalogue
  --seconds   how long each trial of a variant runs (default 2)
  --trials    trials per variant, each compiled afresh (default 3): the
              report gives medians and flags spreads over 10%
  --device    NPU (default), GPU or CPU: the same experiment on another device
  --tiles     the NPU tiles to use (1-3; default: the compiler's choice)
  --cache     a directory to keep compiled models in (startup cost)
  --no-turbo  let the NPU's clock follow load (the default holds it at its
              maximum, which makes trials repeatable: see harness.trial)
  --json      JSON lines on stdout (for jantar) instead of a report
  --save      also write NAME/result.json

Needs OpenVINO with the NPU plugin and Level Zero; the `npu-experiment`
package in jantar's flake sets that up.
"""
import argparse
import importlib.util
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import harness  # noqa: E402


def experiments():
    return sorted(p for p in here.iterdir() if (p / "experiment.py").is_file())


def load(path):
    spec = importlib.util.spec_from_file_location(path.name.replace("-", "_"), path / "experiment.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser(description="Run an NPU experiment.")
    ap.add_argument("name")
    ap.add_argument("--seconds", type=float, default=2)
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--no-turbo", dest="turbo", action="store_false")
    ap.add_argument("--device", default="NPU", choices=["NPU", "GPU", "CPU"])
    ap.add_argument("--tiles", type=int)
    ap.add_argument("--cache")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--save", action="store_true")
    a = ap.parse_args()

    if a.name == "list":
        cat = []
        for p in experiments():
            m = load(p)
            cat.append({"name": p.name, "title": m.TITLE, "real_world": getattr(m, "REAL_WORLD", "")})
        if a.json:
            print(json.dumps(cat))
        else:
            for e in cat:
                print(f"{e['name']:20} {e['title']}")
        return

    path = here / a.name
    if not (path / "experiment.py").is_file():
        sys.exit(f"no experiment {a.name}; try: list")
    settings = harness.Run(device=a.device, turbo=a.turbo, tiles=a.tiles)
    harness.run(load(path), a.name, a.seconds, a.json, path / "result.json" if a.save else None,
                trials=max(1, a.trials), settings=settings, cache=a.cache)


if __name__ == "__main__":
    main()
