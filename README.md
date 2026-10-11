# beam-hud

A BEAM rewrite of `hud` (the Python system monitor in `~/dotfiles/bin/hud`),
on its way to being a dashboard on a dedicated Linux text console (VT9)
drawing to the framebuffer. Gleam holds the pure, typed logic; Elixir holds
the processes.

Status: **milestones 1 and 2**, the data side. Every source hud reads is
sampled by its own process into a time-windowed history, and `mix hud.dump`
prints it as text. There is no renderer yet.

```sh
nix develop                      # Erlang/OTP 28, Elixir 1.18, Gleam 1.19, rebar3 (+ Rust, cairo for later)
mix hud.dump                     # one snapshot of every sensor and series
mix hud.dump --watch             # refresh every 2 s (Ctrl-C twice to quit)
mix test                         # Elixir tests (also builds the Gleam core)
(cd gleam/hud_core && gleam test)  # Gleam tests
```

## Layout

```
beam-hud/
├── flake.nix                  devShell, pinned to the system's nixpkgs revision
├── mix.exs                    Elixir app + the small Mix compiler that builds the Gleam core
├── config/                    config.exs (root, max_points, adaptive, ...), test.exs
├── gleam/hud_core/            Gleam: pure logic, no I/O
│   ├── src/hud_core/
│   │   ├── parse.gleam        /proc/stat, meminfo, net/dev, uptime, pid stat, cgroups,
│   │   │                      CI progress, nmcli and iw output -> typed records
│   │   ├── ring.gleam         time-windowed history bookkeeping (which samples to drop)
│   │   ├── rate.gleam         CPU load, counter rates, NPU/GPU busy, battery W and
│   │   │                      minutes, charger W, build ETA
│   │   ├── polar.gleam        dial maths: age -> angle with laps, value -> radius
│   │   │                      (linear/log, clamped, mirrored with a zero ring), fading
│   │   └── adapt.gleam        adaptive sampling: next interval from recent values
│   └── test/hud_core/         gleeunit tests (recorded samples + hud's own results)
├── lib/
│   ├── beam_hud/
│   │   ├── application.ex     supervision tree
│   │   ├── history.ex         owns every series, in ETS
│   │   ├── sensor.ex          behaviour + the GenServer that runs any source
│   │   ├── sensor_supervisor.ex
│   │   ├── sensors/*.ex       cpu memory net thermal fan battery charger npu gpu wifi ci_runner
│   │   ├── mode.ex            global visible / on-battery flags (:persistent_term)
│   │   ├── core.ex            the Gleam boundary (Gleam records -> Elixir maps)
│   │   ├── sysfs.ex           file reads under a configurable root; realpath
│   │   └── format.ex          hud's number formatting
│   └── mix/tasks/hud.dump.ex  `mix hud.dump`
├── test/                      ExUnit tests; fixtures/capture = recorded /proc and /sys
└── tools/
    ├── capture-fixtures.sh    snapshot this machine's sources into test/fixtures/capture
    └── hud_oracle.py          run hud's own Sampler over the fixtures -> hud_expected.json
```

## How Gleam is built into Mix

The Gleam core is an ordinary Gleam project (`gleam/hud_core`, with its own
`gleam.toml`, `manifest.toml` and `gleam test`). `mix.exs` defines a tiny Mix
compiler, `Mix.Tasks.Compile.HudCore`, that runs first (`compilers:
[:hud_core | Mix.compilers()]`). It runs `gleam build --target erlang` and
prepends each `build/dev/erlang/*/ebin` to the code path. Elixir then calls
Gleam modules as Erlang modules: `:hud_core@parse.cpu_times(text)`. If
`HUD_CORE_BUILD` is set, the compiler skips the Gleam toolchain and just adds
`$HUD_CORE_BUILD/*/ebin`. That's the hook for Nix.

**Why not `mix_gleam`?** I tried it: v0.6.2 does still work with Gleam 1.19
when the Gleam sources sit in the Mix project's own `src/`. But it needs a Mix
archive installed into `MIX_HOME`, and Gleam's Hex dependencies become Mix
dependencies. With the Gleam project as a path dependency, the versions in
`gleam.toml` have to be repeated in `mix.exs` and kept in step (my first try
failed on exactly that `gleam_stdlib` mismatch). The plain approach has fewer
moving parts:

* the Mix project has **no dependencies at all** (OTP and Elixir only);
* the Gleam project's dependencies (gleam_stdlib, gleeunit) are locked with
  checksums in `manifest.toml`;
* for Nix that means two simple derivations: one runs `gleam export
  erlang-shipment` with the Hex tarballs fetched from `manifest.toml`'s
  checksums, and one builds the Mix release with `HUD_CORE_BUILD` pointing at
  the first. No `mixFodDeps` are needed. (Releases will also need the Gleam
  ebins copied into the release; that comes with packaging.)

`BeamHud.Core` documents how Gleam values look from Elixir (`Ok(x)` is
`{:ok, x}`, `None` is `:none`, a record `MemInfo(..)` is `{:mem_info, ...}`)
and converts the records the app keeps into maps.

## Design

### Processes

```
BeamHud.Supervisor (rest_for_one)
├── BeamHud.History            owns the ETS tables
└── BeamHud.SensorSupervisor   (one_for_one)
    ├── Sensor(Cpu)  ├── Sensor(Memory)  ├── ... one per source
```

`BeamHud.Sensor` is a behaviour plus the one GenServer that runs every
source, the way `GenServer` runs your callbacks. A source module only
implements `defaults/0`, `init/1` (find the source; declare series and
windows) and `sample/2` (one reading). Scheduling, pushing to History, backoff
and error handling live in one place, and sources are tested by calling
`init/1` and `sample/2` directly.

A **missing source never crashes**: `init/1` returns `{:unavailable, reason}`,
and the sensor records that, then tries again after 5 s, 10 s, ... up to 5 min.
An exception in a source is treated the same way. So there are no supervisor
restart loops, and a machine without an NPU or a CI runner just shows those as
`off`.

The top level is **`rest_for_one`**, not `one_for_one` as first sketched. If
History restarts, its ETS tables are gone, so the sensors are restarted after
it and declare their series again. A crashing sensor still restarts alone,
and its history survives in History's tables.

### History: one ETS row per sample

* `:beam_hud_samples` (`ordered_set`): `{{series, seq}, t_ms, value}`. Each
  sample carries its own **monotonic timestamp**. The table is ordered, so one
  series' samples sit together in time order, and `History.samples/1` walks just
  that range. A push inserts one small row. Keeping a whole ring in one ETS
  value would copy up to 7200 points on every 250 ms push.
* `:beam_hud_state` (`set`): each series' window bookkeeping (a Gleam
  `ring.Ring`), and each sensor's status and latest values.

Both tables are `:protected`: only History writes, and anyone reads without
sending a message. **Rings are sized by time**: each series keeps a window
(hud's: 5 min for load/mem/net/NPU/GPU, 30 min for temp/clock/power/fan/wifi),
so faster sampling holds more points. Each series is capped at
`config :beam_hud, max_points: 7200` (30 min at 250 ms). Which samples to
drop is decided in Gleam (`ring.trim`, which asks for timestamps through a
callback); History applies it.

### Sampling intervals

Defaults, measured on this machine. Each one can be changed with
`config :beam_hud, BeamHud.Sensors.X, interval: ...`.

| sensor     | interval | notes |
|------------|----------|-------|
| cpu        | 250 ms   | per-core clocks read at most every 1 s (`clock_every`) |
| net        | 250 ms   | |
| gpu        | 250 ms   | per GT (render, media) |
| npu        | 250 ms awake / 2 s suspended | from `power/runtime_status`; reading doesn't wake it |
| thermal    | 500 ms   | coretemp package |
| memory     | 1 s      | |
| fan        | 1 s      | the EC updates about once a second |
| battery    | 1 s      | current/voltage/status → W; capacity and minutes every 10 s (`detail_every`) |
| charger    | 10 s     | USB-C source offer |
| wifi       | 20 s     | nmcli + iw, killed after 10 s; blocks only its own process |
| ci_runner  | 2 s      | `systemctl is-failed` at most every 30 s while stopped |

Battery *status* is read every second along with current and voltage, not
every 10 s, because it sets the sign of the power reading.

**Adaptive sampling** (`config :beam_hud, adaptive: true`, or per sensor):
after each sample the Gleam `adapt.next_interval` looks at the last 8
values of the sensor's first series. It halves the interval when the latest
step is at least half the recent range, grows it by a quarter when the signal
is flat or settling, and keeps it in between. Steps under `:noise` count as
flat. The interval stays between the configured interval and `:max_interval`
(default 8x). It is off by default.

**Mode** (`BeamHud.Mode`, in `:persistent_term`): `visible` and
`on_battery`. The battery sensor sets `on_battery`; the display will set
`visible`. While hidden and on battery, sensors stretch their intervals by
`config :beam_hud, hidden_on_battery_factor:` (default 1, i.e. the mechanism
is in place but does nothing yet).

### Dial maths (polar.gleam)

The angle comes from a sample's real age (`now - t`), not its index, so
irregular sampling (adaptive, backoff, NPU sleeping) plots in the right
place. A window longer than the dial's period wraps into laps. `fade` and
`thinned` are hud's age styling, keyed by the sample's sequence number so
thinning doesn't flicker.

## Checking against hud

`tools/capture-fixtures.sh` snapshots every file hud reads (twice, 2 s apart)
into `test/fixtures/capture/{t0,t1}`, laid out like the real root, with MACs
and SSIDs anonymised. `tools/hud_oracle.py` runs **hud's own `Sampler`**
over those trees, with its file access redirected, and writes
`hud_expected.json`. The Gleam and ExUnit tests check parsed values and
computed rates against that file: CPU load per core, tiers, clocks, memory,
net rates and totals, temperature and fan paths, battery and charger, NPU,
GPU busy per GT, and wifi links.

```sh
tools/capture-fixtures.sh            # re-record (then re-run the oracle)
nix shell nixpkgs#python3 -c python3 -I tools/hud_oracle.py ~/dotfiles/bin/hud \
    test/fixtures/capture > test/fixtures/capture/hud_expected.json
```

Known small differences from hud:

* hud measures intervals as float seconds; beam-hud uses integer
  milliseconds (agreement to ~1e-6 on GPU busy).
* When `iw` omits width, dBm or bitrate, hud keeps the previous value and
  beam-hud reports 0. hud only shows them while connected.
* `round()` is half-away-from-zero in Gleam and Elixir, and half-to-even in
  Python. This only matters for exact .5 values in formatting.
