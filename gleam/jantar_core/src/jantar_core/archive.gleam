//// Consolidated history at coarser time steps, the round-robin archive idea
//// from RRDtool: samples are folded into fixed steps (a minute, an hour),
//// and each finished step keeps the minimum, mean and maximum of what fell in
//// it. Rows past the archive's retention are dropped, so an archive never
//// grows: 24 hours of minutes is 1440 rows, 30 days of hours is 720.
////
//// Steps are aligned to wall-clock time (a minute step starts on the minute)
//// so archives line up across restarts, and timestamps here are wall-clock
//// milliseconds, not monotonic ones.
////
//// This module is the arithmetic only. The caller keeps one open `Step` per
//// series and archive, feeds it samples with `add`, and stores each `Row`
//// that `add` hands back once a step is finished.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

/// An archive's shape: the step length and how long its rows are kept.
pub type Spec {
  Spec(step_ms: Int, keep_ms: Int)
}

/// One minute per row, for a day.
pub const day = Spec(step_ms: 60_000, keep_ms: 86_400_000)

/// One hour per row, for 30 days.
pub const month = Spec(step_ms: 3_600_000, keep_ms: 2_592_000_000)

/// The step being filled: where it starts, and the running min, max, sum and
/// count of the samples in it.
pub type Step {
  Step(start: Int, min: Float, max: Float, sum: Float, count: Int)
}

/// A finished step: its start (wall-clock ms) and the min, mean and max of
/// its samples, with how many there were. An Erlang tuple
/// {row, Start, Min, Mean, Max, Count}.
pub type Row {
  Row(start: Int, min: Float, mean: Float, max: Float, count: Int)
}

/// The start of the step containing `t`.
pub fn step_start(spec: Spec, t: Int) -> Int {
  case int.modulo(t, spec.step_ms) {
    Ok(offset) -> t - offset
    Error(_) -> t
  }
}

/// Fold one sample (at wall-clock `t`) into the open step. Returns the row
/// for the step that just finished, if the sample starts a new one, and the
/// step to keep filling. A sample older than the open step is ignored (the
/// clock went back): the step is kept as it was.
pub fn add(
  spec: Spec,
  open: Option(Step),
  t: Int,
  value: Float,
) -> #(Option(Row), Option(Step)) {
  let start = step_start(spec, t)
  case open {
    None -> #(None, Some(Step(start, value, value, value, 1)))
    Some(step) if start == step.start -> #(
      None,
      Some(Step(
        start,
        float.min(step.min, value),
        float.max(step.max, value),
        step.sum +. value,
        step.count + 1,
      )),
    )
    Some(step) if start > step.start -> #(
      Some(finish(step)),
      Some(Step(start, value, value, value, 1)),
    )
    Some(step) -> #(None, Some(step))
  }
}

/// The row for a step so far.
pub fn finish(step: Step) -> Row {
  Row(
    start: step.start,
    min: step.min,
    mean: step.sum /. int.to_float(int.max(1, step.count)),
    max: step.max,
    count: step.count,
  )
}

/// Rows starting before this wall-clock time are past the archive's
/// retention at `now`.
pub fn expired_before(spec: Spec, now: Int) -> Int {
  now - spec.keep_ms
}
