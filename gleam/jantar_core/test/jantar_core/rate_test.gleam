//// Rates from the recorded t0/t1 pair, checked against hud's own results
//// (tools/hud_oracle.py, test/fixtures/capture/hud_expected.json), plus the
//// battery and ETA arithmetic.

import gleam/list
import gleam/option.{None, Some}
import jantar_core/fixture
import jantar_core/parse.{Progress}
import jantar_core/rate

/// The time between the two snapshots, from their /proc/uptime (hud: dt_ms).
fn dt_ms() -> Int {
  let assert Ok(t0) = parse.uptime(fixture.read("t0", "/proc/uptime"))
  let assert Ok(t1) = parse.uptime(fixture.read("t1", "/proc/uptime"))
  let ms = { t1 -. t0 } *. 1000.0
  assert ms >. 2400.0 && ms <. 2600.0
  2520
}

fn number(snapshot: String, path: String) -> Float {
  let assert Ok(n) = parse.number(fixture.read(snapshot, path))
  n
}

pub fn cpu_loads_capture_test() {
  let prev = parse.cpu_times(fixture.read("t0", "/proc/stat"))
  let cur = parse.cpu_times(fixture.read("t1", "/proc/stat"))
  let assert Ok([all, ..cores]) = rate.cpu_loads(prev, cur)
  // hud: cpu_load 0.08519068845963348; core 3 was pegged at 1.0
  assert fixture.close(all, 0.08519068845963348)
  assert list.length(cores) == 16
  let assert Ok(core0) = list.first(cores)
  assert fixture.close(core0, 0.06967213114754098)
  assert list.drop(cores, 3) |> list.first == Ok(1.0)
}

pub fn cpu_loads_edges_test() {
  let a = [parse.CpuTimes(busy: 10, total: 100)]
  // No previous reading, or the cpu count changed: no load yet.
  assert rate.cpu_loads([], a) == Error(Nil)
  assert rate.cpu_loads(a, list.append(a, a)) == Error(Nil)
  // Total didn't move: 0, not a division by zero.
  assert rate.cpu_loads(a, a) == Ok([0.0])
  // Clamped to 0..1.
  assert rate.cpu_loads(a, [parse.CpuTimes(busy: 50, total: 110)]) == Ok([1.0])
}

pub fn net_rates_capture_test() {
  let #(rx0, tx0) =
    parse.net_totals(parse.net_dev(fixture.read("t0", "/proc/net/dev")))
  let #(rx1, tx1) =
    parse.net_totals(parse.net_dev(fixture.read("t1", "/proc/net/dev")))
  let assert Ok(rx) = rate.per_second(rx0, rx1, dt_ms())
  let assert Ok(tx) = rate.per_second(tx0, tx1, dt_ms())
  // hud: rx 2409.9206349306546, tx 1740.4761904834268 bytes/s
  assert fixture.close(rx, 2409.9206349306546)
  assert fixture.close(tx, 1740.4761904834268)
}

pub fn per_second_edges_test() {
  assert rate.per_second(100, 300, 2000) == Ok(100.0)
  // A counter reset reads 0, never negative; no interval, no rate.
  assert rate.per_second(300, 100, 2000) == Ok(0.0)
  assert rate.per_second(100, 300, 0) == Error(Nil)
}

pub fn gpu_busy_capture_test() {
  let gt = "/sys/devices/pci0000:00/0000:00:02.0/tile0/"
  let busy = fn(g) {
    let p = gt <> g <> "/gtidle/idle_residency_ms"
    let assert Ok(b) =
      rate.busy_from_idle(number("t0", p), number("t1", p), dt_ms())
    b
  }
  // hud: gt0-rc 0.038888888884892836, gt1-mc 0.004761904757766833. hud's
  // interval is the uptime difference as a float (2.5199999...), ours is
  // whole ms, hence the looser tolerance.
  assert fixture.close(busy("gt0") *. 1.0e6, 0.038888888884892836 *. 1.0e6)
  assert fixture.close(busy("gt1") *. 1.0e6, 0.004761904757766833 *. 1.0e6)
}

pub fn npu_busy_test() {
  let p = "/sys/class/accel/accel0/device/npu_busy_time_us"
  // hud: load 0.0 (the NPU was asleep)
  assert rate.busy_fraction(number("t0", p), number("t1", p), dt_ms())
    == Ok(0.0)
  // 0.5 s busy in 2 s = 25%, and clamped at 100%.
  assert rate.busy_fraction(0.0, 500_000.0, 2000) == Ok(0.25)
  assert rate.busy_fraction(0.0, 5_000_000.0, 2000) == Ok(1.0)
}

pub fn battery_test() {
  // 1.5 A at 15.4 V = 23.1 W, negative while discharging.
  assert fixture.close(
    rate.battery_watts(1_500_000.0, 15_400_000.0, "Discharging"),
    -23.1,
  )
  assert fixture.close(
    rate.battery_watts(1_500_000.0, 15_400_000.0, "Charging"),
    23.1,
  )
  // hud: 0 W, no estimate, while "Not charging" at 100%.
  let cur = number("t1", "/sys/class/power_supply/BAT1/current_now")
  let volt = number("t1", "/sys/class/power_supply/BAT1/voltage_now")
  assert rate.battery_watts(cur, volt, "Not charging") == 0.0
  assert rate.battery_minutes("Not charging", cur, 1.0, 2.0) == None
  // 2 Ah left at 1 A = 120 min; 1 Ah to go at 2 A = 30 min.
  assert rate.battery_minutes("Discharging", 1.0e6, 2.0e6, 4.0e6) == Some(120.0)
  assert rate.battery_minutes("Charging", 2.0e6, 3.0e6, 4.0e6) == Some(30.0)
  assert rate.battery_minutes("Discharging", 0.0, 2.0e6, 4.0e6) == None
  // hud: charger 100.0 W (20 V x 5 A on the online USB-C port)
  assert rate.charger_watts(20_000_000.0, 5_000_000.0) == 100.0
}

pub fn eta_test() {
  let p = fn(pkg, done) { Progress(pkg, done, 1000.0) }
  let e = rate.eta_new()
  let #(e, est) = rate.eta_update(e, 0, p("llvm", 100.0))
  assert est == None
  // 30 s later: not enough span yet (needs a minute).
  let #(e, est) = rate.eta_update(e, 30_000, p("llvm", 130.0))
  assert est == None
  // 100 s after the start, 100 done: 1/s, 800 left = 800 s.
  let #(e, est) = rate.eta_update(e, 100_000, p("llvm", 200.0))
  assert est == Some(800.0)
  // Samples older than 5 minutes drop out of the window.
  let #(e, _) = rate.eta_update(e, 400_000, p("llvm", 500.0))
  assert list.map(e.samples, fn(s) { s.0 }) == [100_000, 400_000]
  // A new package restarts the history.
  let #(e, est) = rate.eta_update(e, 410_000, p("compiler", 5.0))
  assert est == None
  assert e.samples == [#(410_000, 5.0)]
  // So does progress going backwards.
  let #(e, _) = rate.eta_update(e, 420_000, p("compiler", 2.0))
  assert e.samples == [#(420_000, 2.0)]
  // No progress over the window: no estimate.
  let #(_, est) = rate.eta_update(e, 500_000, p("compiler", 2.0))
  assert est == None
}

pub fn mean_test() {
  assert rate.mean([]) == Error(Nil)
  assert rate.mean([1.0, 2.0, 6.0]) == Ok(3.0)
}
