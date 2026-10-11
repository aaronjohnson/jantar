# Plan: live NPU section

Status (2026-10-10): built. `c/npu_port` (the Port), `Jantar.NpuPort`,
`Jantar.Sensors.NpuCounters`, and the DMA dial in GPU · NPU. Found while
building it:

- Even `zeInit` and device enumeration wake the NPU, so the port initialises
  nothing until OPEN. After CLOSE (context destroyed, the loader still
  initialised, the process alive) the NPU suspends again within 0.5 s.
- Streaming doesn't move `npu_busy_time_us`, so busy time is what says the
  NPU is working: open when it moves, close at the first second it doesn't.
- `NOC_timestamp` ticks at 19.2 MHz (10 reports at 100 ms = 19.2e6 ticks);
  rates are timed with it. NOC counters restart at 0 with each streamer.
- `Freq_dpu_hz` / `Freq_nce_hz` are kHz (950000 while sysfs said 950 MHz).

Still to check on the real service: the NPU keeps suspending when idle with
jantar running (watch `runtime_suspended_time` grow).

## What the hardware offers

Intel NPU 5 (Panther Lake, "Intel(R) AI Boost", `/dev/accel/accel0`, mode 0666).

- sysfs (already read by `Jantar.Sensors.Npu`): `npu_busy_time_us`,
  `npu_current_frequency_mhz`, `npu_max_frequency_mhz` (2050),
  `npu_memory_utilization`, `power/runtime_status`.
- Level Zero metrics (`tools/npu-metrics.c` lists them; needs
  `ZET_ENABLE_METRICS=1` and `LD_LIBRARY_PATH=/run/opengl-driver/lib`, since the
  1.32 loader doesn't find drivers on NixOS otherwise):
  - **NOC** (event + time based): `NOC_noc` (total DMA), `NOC_DMA_00`,
    `NOC_DMA_01`, `L2C_Riscv`, `L2C_Shave`, `NOC_timestamp`. Free-running
    cumulative counters; diff successive reports for rates.
  - **FRC**: `FRC_Fixed`, `FRC_Dynamic`, `FRC_timestamp` (cycle counters).
  - **FREQ** (time based only): `Freq_dpu_hz`, `Freq_nce_hz`, `Freq_timestamp`.
- No direct MAC-array utilisation counter.

## Measured

- `tools/npu-profile.py` (OpenVINO, `PERF_COUNT`): a small mixed model ran
  DPU 247 µs, DMA 16 µs, SHAVE 2 µs. ReLU/swish/GELU fused into the
  convolutions (DPU post-processing); only softmax ran on SHAVE.
- Streaming NOC while that model looped (~3,500 inferences/s): NOC_noc
  ~3.1e9/s (probably bytes, ~3 GB/s), DMA_00 ~1.65e9/s, DMA_01 ~1.43e9/s,
  L2C_Riscv ~1.9e7/s, L2C_Shave ~7.3e3/s. 10 reports/s at a 100 ms period
  while busy; one per read when idle.
- **Each streamer read wakes a suspended NPU** (runtime_status flips to
  active, then back). So stream only while the NPU is already awake for
  real work; never open the streamer just to watch an idle NPU.

The probe that streamed is in the session scratchpad only; rewrite it as the
port (below). Its essentials: `zeInit`, first driver/device, `zeContextCreate`,
`zetMetricGroupGet` + match by name, `zetContextActivateMetricGroups`,
`zetMetricStreamerOpen` (samplingPeriod 100000000 ns, notifyEveryNReports
100), then `zetMetricStreamerReadData` (size query, then read) and
`zetMetricGroupCalculateMetricValues` (METRIC_VALUES), values are `ui64`,
`metricCount` per report.

## Design

- `c/npu_port`: a C program run as a Port (like `c/cairo_port`), linked
  against nixpkgs `level-zero` (`libze_loader`). Protocol `{:packet, 4}`:
  OPEN group / READ / CLOSE; READ returns the last report's cumulative
  values (and the report count). Keep the context open between reads.
- `Jantar.Sensors.NpuDetail` (or extend `Npu`): every 1 s, only when the Npu
  sensor says awake (`runtime_status == active` and busy time moving): open
  the port's streamer if closed, read, diff against the previous report to
  get rates. When the NPU suspends, CLOSE the streamer (and maybe the port).
  Series `{:npu, :dma}`, `{:npu, :shave}`, `{:npu, :riscv}` (per second),
  `{:npu, :nce_hz}`. Gaps while asleep.
- Frame: an NPU dial (in the GPU · NPU section) with DMA as the main trace,
  SHAVE and RISC-V as smaller inner traces (log scale), NCE clock in the
  info line. Keep the existing NPU busy dial or merge.
- NixOS module: the service needs `DeviceAllow /dev/accel/accel0 rw`,
  `ZET_ENABLE_METRICS=1`, and `LD_LIBRARY_PATH=/run/opengl-driver/lib` (or
  `ZE_ENABLE_ALT_DRIVERS`) for driver discovery; the port's path passed like
  `CAIRO_PORT_BIN` (`NPU_PORT_BIN`), built in its own derivation.
- Tests: protocol tests with the port absent/failing (sensor unavailable,
  no crash); a demo snapshot entry for screenshots; VM test unaffected (no
  NPU there, sensor unavailable).
- Check after deploying: NPU still suspends when idle (watch
  `runtime_suspended_time` grow) with jantar running.
