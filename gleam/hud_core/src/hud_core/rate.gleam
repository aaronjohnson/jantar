//// Turning raw readings into the numbers hud shows: counter deltas into rates,
//// jiffies into CPU load, busy/idle times into utilisation, battery current and
//// voltage into watts and minutes, and build progress into an ETA.
////
//// Times are integer milliseconds (monotonic) throughout; results are Floats.
//// Functions that need two readings return Error(Nil) when the interval is not
//// positive, so a sensor's very first sample simply produces no rate.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import hud_core/parse.{type CpuTimes, type Progress}

/// Clamp to the range 0..1.
pub fn unit(x: Float) -> Float {
  float.clamp(x, min: 0.0, max: 1.0)
}

fn seconds(dt_ms: Int) -> Float {
  int.to_float(dt_ms) /. 1000.0
}

// ------------------------------------------------------------------ CPU

/// Load of each line of /proc/stat (aggregate first, then each cpu) between
/// two readings, 0..1. Error if the cpu count changed or there is no previous
/// reading (hud's read_cpu). A cpu whose total didn't advance reads 0.
pub fn cpu_loads(
  prev: List(CpuTimes),
  cur: List(CpuTimes),
) -> Result(List(Float), Nil) {
  case prev != [] && list.length(prev) == list.length(cur) {
    False -> Error(Nil)
    True ->
      Ok(
        list.map2(cur, prev, fn(c, p) {
          case c.total > p.total {
            True ->
              unit(
                int.to_float(c.busy - p.busy) /. int.to_float(c.total - p.total),
              )
            False -> 0.0
          }
        }),
      )
  }
}

// ------------------------------------------------------------------ counters

/// A byte counter's rate per second, never negative (counters can reset).
pub fn per_second(prev: Int, cur: Int, dt_ms: Int) -> Result(Float, Nil) {
  case dt_ms > 0 {
    True -> Ok(float.max(0.0, int.to_float(cur - prev) /. seconds(dt_ms)))
    False -> Error(Nil)
  }
}

/// Utilisation from a cumulative busy-time counter in microseconds, 0..1:
/// the NPU's npu_busy_time_us (hud's read_npu).
pub fn busy_fraction(
  prev_us: Float,
  cur_us: Float,
  dt_ms: Int,
) -> Result(Float, Nil) {
  case dt_ms > 0 {
    True -> Ok(unit({ cur_us -. prev_us } /. { int.to_float(dt_ms) *. 1000.0 }))
    False -> Error(Nil)
  }
}

/// Utilisation from a cumulative idle-time counter in milliseconds, 0..1:
/// a GPU GT's gtidle/idle_residency_ms (hud's read_gpu).
pub fn busy_from_idle(
  prev_ms: Float,
  cur_ms: Float,
  dt_ms: Int,
) -> Result(Float, Nil) {
  case dt_ms > 0 {
    True -> Ok(unit(1.0 -. { cur_ms -. prev_ms } /. int.to_float(dt_ms)))
    False -> Error(Nil)
  }
}

// ------------------------------------------------------------------ power

/// Battery power in watts from current_now (µA) and voltage_now (µV):
/// negative while discharging, positive otherwise (hud's read_power).
pub fn battery_watts(
  current_ua: Float,
  voltage_uv: Float,
  status: String,
) -> Float {
  let w = current_ua *. voltage_uv /. 1.0e12
  case status {
    "Discharging" -> 0.0 -. w
    _ -> w
  }
}

/// Minutes until empty (discharging) or full (charging), from current_now
/// (µA) and charge_now / charge_full (µAh). None when idle or unknown.
pub fn battery_minutes(
  status: String,
  current_ua: Float,
  charge_now: Float,
  charge_full: Float,
) -> Option(Float) {
  case current_ua >. 0.0, status {
    True, "Discharging" -> Some(charge_now /. current_ua *. 60.0)
    True, "Charging" ->
      Some({ charge_full -. charge_now } /. current_ua *. 60.0)
    _, _ -> None
  }
}

/// A USB-C source's offer in watts: voltage_now (µV) x current_max (µA).
pub fn charger_watts(voltage_uv: Float, current_max_ua: Float) -> Float {
  voltage_uv *. current_max_ua /. 1.0e12
}

// ------------------------------------------------------------------ build ETA

/// Recent build progress samples #(t_ms, done) for one package, oldest first.
pub type Eta {
  Eta(package: String, samples: List(#(Int, Float)))
}

pub const eta_window_ms = 300_000

pub const eta_min_span_ms = 60_000

pub fn eta_new() -> Eta {
  Eta(package: "", samples: [])
}

/// Add a progress reading taken at `t_ms` and estimate the seconds left from
/// the rate over the last 5 minutes (hud's read_runner). The history restarts
/// when the package changes or `done` goes backwards. No estimate until the
/// samples span a minute and show progress.
pub fn eta_update(eta: Eta, t_ms: Int, p: Progress) -> #(Eta, Option(Float)) {
  let restart = case list.last(eta.samples) {
    Ok(#(_, last_done)) -> p.package != eta.package || p.done <. last_done
    Error(_) -> p.package != eta.package
  }
  let kept = case restart {
    True -> []
    False -> eta.samples
  }
  let samples =
    list.append(kept, [#(t_ms, p.done)])
    |> list.filter(fn(s) { s.0 >= t_ms - eta_window_ms })
  let estimate = case list.first(samples), list.last(samples) {
    Ok(#(t0, d0)), Ok(#(t1, d1)) -> {
      let span_ms = t1 - t0
      let gained = d1 -. d0
      case span_ms >= eta_min_span_ms && gained >. 0.0 {
        True -> Some({ p.total -. p.done } /. { gained /. seconds(span_ms) })
        False -> None
      }
    }
    _, _ -> None
  }
  #(Eta(package: p.package, samples: samples), estimate)
}

// ------------------------------------------------------------------ summaries

/// Mean of a list, Error if empty.
pub fn mean(values: List(Float)) -> Result(Float, Nil) {
  case values {
    [] -> Error(Nil)
    _ -> Ok(float.sum(values) /. int.to_float(list.length(values)))
  }
}
