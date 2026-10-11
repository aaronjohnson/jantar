//// Adaptive sampling: choose a sensor's next interval from what it has seen.
////
//// When a value is moving (the latest step is large compared with the recent
//// range), sample faster, down to `min_ms`; when it is flat, back off
//// gradually towards `max_ms`. Steps smaller than `noise` count as flat, so
//// jitter in an idle signal doesn't keep the sensor awake.

import gleam/float
import gleam/int
import gleam/list

pub type Policy {
  Policy(min_ms: Int, max_ms: Int, noise: Float)
}

/// A step at least this share of the recent range means "moving": halve.
pub const fast_share = 0.5

/// A step below this share of the range means "settling": grow by a quarter.
/// In between, keep the current interval.
pub const slow_share = 0.2

/// The next interval in ms, given recent values (oldest first; the caller
/// decides how many, e.g. the last 8) and the current interval.
pub fn next_interval(
  values: List(Float),
  current_ms: Int,
  policy: Policy,
) -> Int {
  let next = case list.reverse(values) {
    [latest, previous, _, ..] -> {
      let step = float.absolute_value(latest -. previous)
      let range = spread(values)
      case step <=. policy.noise || range <=. policy.noise {
        // Flat: decay towards the maximum.
        True -> grow(current_ms)
        False -> {
          let share = step /. range
          case share >=. fast_share, share <. slow_share {
            True, _ -> current_ms / 2
            False, True -> grow(current_ms)
            False, False -> current_ms
          }
        }
      }
    }
    // Too few samples to judge: stay put.
    _ -> current_ms
  }
  int.clamp(next, min: policy.min_ms, max: policy.max_ms)
}

/// Grow by a quarter, and by at least 1 ms so small intervals still move.
fn grow(ms: Int) -> Int {
  ms + int.max(1, ms / 4)
}

/// max - min of the values (0 for an empty list).
fn spread(values: List(Float)) -> Float {
  case values {
    [] -> 0.0
    [first, ..] -> {
      let #(lo, hi) =
        list.fold(values, #(first, first), fn(acc, v) {
          #(float.min(acc.0, v), float.max(acc.1, v))
        })
      hi -. lo
    }
  }
}
