"""Run an NPU example: python3 -I run.py NAME [--seconds S] [--json] [--save]

  NAME        an example folder (01-matrix), or `list` for the catalogue
  --seconds   how long each variant runs (default 5): longer shows up
              better on jantar's dials
  --json      JSON lines on stdout (for jantar) instead of a report
  --save      also write NAME/result.json

Needs OpenVINO with the NPU plugin and Level Zero; the `npu-example`
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


def examples():
    return sorted(p for p in here.iterdir() if (p / "example.py").is_file())


def load(path):
    spec = importlib.util.spec_from_file_location(path.name.replace("-", "_"), path / "example.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser(description="Run an NPU example.")
    ap.add_argument("name")
    ap.add_argument("--seconds", type=float, default=5)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--save", action="store_true")
    a = ap.parse_args()

    if a.name == "list":
        cat = [{"name": p.name, "title": load(p).TITLE} for p in examples()]
        if a.json:
            print(json.dumps(cat))
        else:
            for e in cat:
                print(f"{e['name']:20} {e['title']}")
        return

    path = here / a.name
    if not (path / "example.py").is_file():
        sys.exit(f"no example {a.name}; try: list")
    harness.run(load(path), a.name, a.seconds, a.json, path / "result.json" if a.save else None)


if __name__ == "__main__":
    main()
