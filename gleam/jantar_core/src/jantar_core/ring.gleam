//// A history window: the bookkeeping for a ring buffer of timestamped
//// samples, kept by time rather than by count.
////
//// Each sample gets a sequence number when it is pushed (0, 1, 2, ...). The
//// ring remembers the oldest number still held (`first`) and the next one to
//// hand out (`next`), so the samples held are first..next-1. A sample leaves
//// when it is older than `window_ms` or when there are more than `max_points`.
//// Faster sampling therefore holds more points over the same window, and the
//// cap bounds memory.
////
//// The samples themselves live elsewhere (jantar keeps one ETS row per
//// sample, so a push copies one small tuple instead of the whole history).
//// This module only decides *which* sequence numbers to drop: `trim` asks the
//// caller for a sample's timestamp through a function. Sequence numbers also
//// give each sample a stable identity as it ages (hud's `Hist.total`), which the
//// dials use to thin old dots without flicker.
////
//// Samples crossing into Erlang/Elixir are plain tuples #(t_ms, value), i.e.
//// {T, V}, so Elixir can pass them without wrapping.

import gleam/int

pub type Ring {
  Ring(window_ms: Int, max_points: Int, first: Int, next: Int)
}

/// An empty ring keeping `window_ms` of history, at most `max_points` samples
/// (at least 2, so there is always a "previous" sample for deltas).
pub fn new(window_ms window_ms: Int, max_points max_points: Int) -> Ring {
  Ring(
    window_ms: window_ms,
    max_points: int.max(2, max_points),
    first: 0,
    next: 0,
  )
}

/// How many samples are held.
pub fn size(ring: Ring) -> Int {
  ring.next - ring.first
}

/// How many samples were ever pushed (the next sequence number).
pub fn total(ring: Ring) -> Int {
  ring.next
}

/// Reserve the sequence number for a new sample. Call `trim` afterwards.
pub fn push(ring: Ring) -> #(Ring, Int) {
  #(Ring(..ring, next: ring.next + 1), ring.next)
}

/// Drop samples that fall outside the window (relative to `now_ms`, normally
/// the newest sample's time) or over the point cap, oldest first. The newest
/// sample is always kept. `time_of(seq)` returns a held sample's timestamp; a
/// sample it can't find is treated as gone.
///
/// Returns the new ring and the sequence numbers to delete from storage.
pub fn trim(
  ring: Ring,
  now_ms: Int,
  time_of: fn(Int) -> Result(Int, Nil),
) -> #(Ring, List(Int)) {
  trim_loop(ring, now_ms, time_of, [])
}

fn trim_loop(
  ring: Ring,
  now_ms: Int,
  time_of: fn(Int) -> Result(Int, Nil),
  dropped: List(Int),
) -> #(Ring, List(Int)) {
  let drop = fn() {
    trim_loop(Ring(..ring, first: ring.first + 1), now_ms, time_of, [
      ring.first,
      ..dropped
    ])
  }
  case size(ring) {
    n if n <= 1 -> #(ring, dropped)
    n if n > ring.max_points -> drop()
    _ ->
      case time_of(ring.first) {
        Error(_) -> drop()
        Ok(t) if t < now_ms - ring.window_ms -> drop()
        Ok(_) -> #(ring, dropped)
      }
  }
}

/// The sequence numbers held, oldest first.
pub fn seqs(ring: Ring) -> List(Int) {
  case size(ring) {
    0 -> []
    _ ->
      int.range(
        from: ring.next - 1,
        to: ring.first - 1,
        with: [],
        run: fn(acc, i) { [i, ..acc] },
      )
  }
}
