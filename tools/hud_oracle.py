"""Run the reference hud's own Sampler over a captured fixture pair and print
what it computes, so the Gleam and Elixir tests can check against hud itself.

    nix shell nixpkgs#python3 -c python3 -I tools/hud_oracle.py \
        ~/dotfiles/bin/hud test/fixtures/capture

File access inside hud is redirected into the fixture tree (t0, then t1); the
time between the two readings is taken from their /proc/uptime.
"""

import builtins
import glob
import importlib.machinery
import importlib.util
import json
import os
import sys

hud_path, fixtures = sys.argv[1], os.path.abspath(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("hud", hud_path)
spec = importlib.util.spec_from_loader("hud", loader)
hud = importlib.util.module_from_spec(spec)
loader.exec_module(hud)

root = None                                     # the snapshot being read
real = dict(open=builtins.open, glob=glob.glob, access=os.access, exists=os.path.exists,
            realpath=os.path.realpath, isdir=os.path.isdir)


def at(p):
    return root + p if p.startswith("/") else p


def unroot(p):
    return p[len(root):] if p.startswith(root) else p


hud.open = lambda p, *a, **k: real["open"](at(p), *a, **k)
hud.glob.glob = lambda p: [unroot(x) for x in real["glob"](at(p))]
hud.os.access = lambda p, m: real["access"](at(p), m)
hud.os.path.exists = lambda p: real["exists"](at(p))
hud.os.path.isdir = lambda p: real["isdir"](at(p))
hud.os.path.realpath = lambda p: unroot(real["realpath"](at(p)))


def uptime(snap):
    with real["open"](os.path.join(fixtures, snap, "proc/uptime")) as f:
        return float(f.read().split()[0])


t0, t1 = uptime("t0"), uptime("t1")
root = os.path.join(fixtures, "t0")
s = hud.Sampler(2.0)                            # discover() runs against t0
s.read_cpu(); s.read_mem(); s.read_net(None); s.read_npu(None); s.read_gpu(t0)
root = os.path.join(fixtures, "t1")
dt = t1 - t0
s.read_cpu(); s.read_mem(); s.read_net(dt); s.read_npu(dt); s.read_gpu(t1)
s.read_slow(); s.read_battery()
with real["open"](os.path.join(fixtures, "t1", "wifi.txt")) as f:
    s.wifi_pending = f.read()
s.take_wifi()

out = dict(
    dt_ms=round(dt * 1000),
    cpu_ids=s.cpu_ids, kinds=s.kinds, max_mhz=s.max_mhz,
    cpu_load=s.cpu_load, core_load=s.core_load,
    mem_used=s.H["mem"].last(), mem_total_kb=s.mem["MemTotal"],
    rx_total=s.rx_total, tx_total=s.tx_total, rx=s.rx, tx=s.tx,
    npu=s.npu, gpu=s.gpu, gpu_driver=s.gpu_driver, gts=s.gts,
    temp_path=s.temp_path, temp=s.temp, fan_path=s.fan_path, fan=s.fan,
    clock_ghz=s.clock, freqs_mhz=s.freqs,
    bat=s.bat, bat_dir=s.bat_dir,
    wifi=dict(s.wifi, links=[list(l) for l in s.wifi["links"]]),
)
json.dump(out, sys.stdout, indent=1, sort_keys=True)
print()
