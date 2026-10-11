//// The history window, with a Dict standing in for the ETS table that holds
//// the samples in jantar.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import jantar_core/ring.{type Ring}

/// Push a sample at t into the ring and the store, trimming as History does.
fn push(state: #(Ring, Dict(Int, Int)), t: Int) -> #(Ring, Dict(Int, Int)) {
  let #(r, store) = state
  let #(r, seq) = ring.push(r)
  let store = dict.insert(store, seq, t)
  let #(r, dropped) = ring.trim(r, t, fn(s) { dict.get(store, s) })
  #(r, dict.drop(store, dropped))
}

fn times(state: #(Ring, Dict(Int, Int))) -> List(Int) {
  let #(r, store) = state
  list.filter_map(ring.seqs(r), fn(s) { dict.get(store, s) })
}

pub fn keeps_a_time_window_test() {
  // 10 s window, sampled every 1 s: holds the last 11 samples (t-10..t).
  let state =
    range(0, 30)
    |> list.fold(
      #(ring.new(window_ms: 10_000, max_points: 100), dict.new()),
      fn(s, i) { push(s, i * 1000) },
    )
  assert times(state) == list.map(range(20, 30), fn(i) { i * 1000 })
  assert ring.size(state.0) == 11
  // Sequence numbers keep counting: a sample's identity survives ageing.
  assert ring.total(state.0) == 31
  assert ring.seqs(state.0) == range(20, 30)
}

pub fn faster_sampling_holds_more_test() {
  // The same 10 s window at 250 ms holds 41 points.
  let state =
    range(0, 200)
    |> list.fold(
      #(ring.new(window_ms: 10_000, max_points: 7200), dict.new()),
      fn(s, i) { push(s, i * 250) },
    )
  assert ring.size(state.0) == 41
}

pub fn point_cap_test() {
  // A long window but at most 5 points.
  let state =
    range(0, 20)
    |> list.fold(
      #(ring.new(window_ms: 1_000_000, max_points: 5), dict.new()),
      fn(s, i) { push(s, i) },
    )
  assert times(state) == [16, 17, 18, 19, 20]
}

pub fn irregular_and_gaps_test() {
  // After a long pause (say the sensor backed off) everything older than the
  // window goes; the newest sample always stays.
  let s = #(ring.new(window_ms: 5000, max_points: 100), dict.new())
  let s = push(s, 0) |> push(1000) |> push(1500) |> push(60_000)
  assert times(s) == [60_000]
  let s = push(s, 62_000)
  assert times(s) == [60_000, 62_000]
}

pub fn minimum_size_test() {
  assert ring.new(window_ms: 1000, max_points: 0).max_points == 2
  assert ring.seqs(ring.new(window_ms: 1000, max_points: 10)) == []
}

pub fn missing_samples_are_dropped_test() {
  // If storage lost a sample, trim treats it as gone rather than stalling.
  let r = ring.new(window_ms: 10_000, max_points: 10)
  let #(r, _) = ring.push(r)
  let #(r, _) = ring.push(r)
  let #(r, dropped) = ring.trim(r, 0, fn(_) { Error(Nil) })
  assert dropped == [0]
  assert ring.size(r) == 1
}

/// from..to inclusive.
fn range(from: Int, to: Int) -> List(Int) {
  int.range(from: to, to: from - 1, with: [], run: list.prepend)
}
