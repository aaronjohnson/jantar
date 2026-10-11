//// Dial maths: angles and laps from real ages, radii on linear and log
//// scales with clamping, mirrored dials and their zero ring. The dials used
//// here are hud's own (TEMP, POWER, NET, NPU).

import gleam/float
import gleam/option.{None, Some}
import hud_core/fixture
import hud_core/polar.{Linear, Log}

const r0 = 0.36

const r1 = 0.88

const minute = 60_000

fn pi() -> Float {
  3.141592653589793
}

// hud: Dial("TEMP", period=300, lo=30, hi=100) over a 30 min history.
fn temp() {
  polar.dial(Linear(30.0, 100.0), False, 30 * minute, Some(5 * minute))
}

// hud: Dial("POWER", period=600, log=(0, 2), mirrored=True), 1..100 W.
fn power() {
  polar.dial(Log(0.0, 2.0), True, 30 * minute, Some(10 * minute))
}

// hud: Dial("NET", log=(2, 8), mirrored=True), 100 B/s..100 MB/s, 5 min.
fn net() {
  polar.dial(Log(2.0, 8.0), True, 5 * minute, None)
}

// ------------------------------------------------------------------ angles and laps

pub fn laps_test() {
  assert polar.laps(temp()) == 6
  assert polar.laps(power()) == 3
  // No period: the window is one lap.
  assert polar.laps(net()) == 1
  assert net().period_ms == 5 * minute
  // Never fewer than one lap, even if the period is longer than the window.
  assert polar.laps(polar.dial(
      Linear(0.0, 1.0),
      False,
      minute,
      Some(10 * minute),
    ))
    == 1
}

pub fn angle_test() {
  let p = 4 * minute
  // Now is 12 o'clock (-pi/2); a quarter period ago is 9 o'clock (-pi):
  // anticlockwise on screen.
  assert fixture.close(polar.angle(0, p), 0.0 -. pi() /. 2.0)
  assert fixture.close(polar.angle(minute, p), 0.0 -. pi())
  assert fixture.close(polar.angle(2 * minute, p), 0.0 -. 1.5 *. pi())
  // A whole period ago is back at 12 o'clock, one lap further in.
  assert fixture.close(polar.angle(p, p), 0.0 -. pi() /. 2.0)
  assert polar.lap(p - 1, p) == 0
  assert polar.lap(p, p) == 1
  assert polar.lap(5 * p + 7, p) == 5
  // Ages from the future (clock skew) are treated as now.
  assert fixture.close(polar.angle(-500, p), 0.0 -. pi() /. 2.0)
}

pub fn irregular_samples_place_by_time_test() {
  // Two samples 3 s and 63 s old land a minute apart, however many samples
  // were taken in between.
  let d = temp()
  let now = 1_000_000
  let assert Some(#(_, a)) = polar.place(d, now, #(now - 3000, 50.0), r0, r1)
  let assert Some(#(_, b)) = polar.place(d, now, #(now - 63_000, 50.0), r0, r1)
  // One minute of a 5 minute lap = 2pi/5.
  assert fixture.close(a -. b, 2.0 *. pi() /. 5.0)
}

pub fn ticks_test() {
  assert polar.tick_ms(30 * minute) == 5 * minute
  assert polar.tick_ms(20 * minute) == 5 * minute
  assert polar.tick_ms(5 * minute) == minute
  assert polar.tick_ms(2 * minute) == 30_000
}

// ------------------------------------------------------------------ value -> radius

pub fn linear_test() {
  let d = temp()
  assert polar.reach(d, 30.0) == 0.0
  assert polar.reach(d, 65.0) == 0.5
  assert polar.radius(d, 100.0, r0, r1) == r1
  // Clamped at both ends.
  assert polar.reach(d, 10.0) == 0.0
  assert polar.reach(d, 130.0) == 1.0
  assert polar.radius(d, 130.0, r0, r1) == r1
  assert polar.radius(d, -5.0, r0, r1) == r0
}

pub fn log_test() {
  let d = net()
  // 10 kB/s is 10^4: (4 - 2) / (8 - 2) = 1/3 of the way.
  assert fixture.close(polar.reach(d, 10_000.0), 1.0 /. 3.0)
  // Below the scale clamps to 0, above to 1.
  assert polar.reach(d, 5.0) == 0.0
  assert polar.reach(d, 1.0e12) == 1.0
  // Zero (and below-scale) values aren't drawn on a log dial.
  assert !polar.visible(d, 0.0)
  assert !polar.visible(d, 5.0)
  assert polar.place(d, 0, #(0, 0.0), r0, r1) == None
  assert polar.visible(d, 1000.0)
  // Magnitude only: -10 kB/s reaches as far as +10 kB/s.
  assert polar.reach(d, -10_000.0) == polar.reach(d, 10_000.0)
}

pub fn mirrored_zero_ring_test() {
  let d = power()
  let mid = polar.zero_ring(r0, r1)
  assert fixture.close(mid, 0.62)
  // 10 W charging sits halfway out from the zero ring, 10 W discharging
  // halfway in.
  assert fixture.close(
    polar.radius(d, 10.0, r0, r1),
    mid +. 0.5 *. { r1 -. mid },
  )
  assert fixture.close(
    polar.radius(d, -10.0, r0, r1),
    mid -. 0.5 *. { r1 -. mid },
  )
  // Full scale reaches r1 outward and r0 inward.
  assert fixture.close(polar.radius(d, 100.0, r0, r1), r1)
  assert fixture.close(polar.radius(d, -500.0, r0, r1), r0)
  // Zero is on the zero ring (though a log dial doesn't draw it).
  assert polar.radius(d, 0.0, r0, r1) == mid
}

pub fn mirrored_linear_test() {
  // A mirrored linear dial scales by the larger of |lo| and |hi|.
  let d = polar.dial(Linear(-20.0, 40.0), True, minute, None)
  assert polar.reach(d, -20.0) == 0.5
  assert polar.reach(d, 40.0) == 1.0
  assert fixture.close(polar.radius(d, -20.0, 0.0, 1.0), 0.25)
}

// ------------------------------------------------------------------ auto range and fading

pub fn auto_range_test() {
  // hud's FAN dial: 0..6000, step 1000, widened to take in 7300 rpm.
  assert polar.auto_range(0.0, 6000.0, 1000.0, [1200.0, 7300.0])
    == #(0.0, 8000.0)
  // TEMP 30..100, step 10: a 24 C reading pulls lo down to 20.
  assert polar.auto_range(30.0, 100.0, 10.0, [24.0, 50.0]) == #(20.0, 100.0)
  assert polar.auto_range(30.0, 100.0, 10.0, []) == #(30.0, 100.0)
  // hi is kept above lo.
  let #(lo, hi) = polar.auto_range(5.0, 5.0, 1.0, [])
  assert hi >. lo
}

pub fn keep_and_fade_test() {
  // keep is deterministic and in 0..1.
  assert polar.keep(12_345) == polar.keep(12_345)
  let k = polar.keep(987_654_321)
  assert k >=. 0.0 && k <. 1.0
  assert polar.keep(0) == 0.0
  // The newest three always show, bold.
  assert !polar.thinned(0, 1.0, 1)
  assert !polar.thinned(2, 1.0, 1)
  assert polar.fade(2, 0.9) == polar.Newest
  assert polar.fade(3, 0.4) == polar.Recent
  assert polar.fade(3, 0.41) == polar.Old
  // Brand-new samples (age 0) are never thinned, whatever their seq.
  assert !polar.thinned(3, 0.0, 1)
  // At the end of the window about 70% of dots are dropped.
  let dropped = count(0, 10_000, fn(seq) { polar.thinned(10, 1.0, seq) })
  assert float.absolute_value(int_to_float(dropped) /. 10_000.0 -. 0.7) <. 0.05
}

fn count(i: Int, n: Int, pred: fn(Int) -> Bool) -> Int {
  case i >= n {
    True -> 0
    False ->
      case pred(i) {
        True -> 1
        False -> 0
      }
      + count(i + 1, n, pred)
  }
}

@external(erlang, "erlang", "float")
fn int_to_float(i: Int) -> Float

// ------------------------------------------------------------------ dense series

pub fn dense_test() {
  // 1200 samples on one lap of ~750 px with a dot every 3 px: dense.
  assert polar.dense(1200, 1, 250.0)
  // 1800 samples over 15 laps = 120 per lap: dots.
  assert !polar.dense(1800, 15, 250.0)
}

pub fn buckets_test() {
  // Ages 1100, 1000 (bucket 1) and 900, 100, 0 ms (bucket 0) at now = 2000.
  let samples = [
    #(900, 4.0),
    #(1000, 1.0),
    #(1100, 3.0),
    #(1900, 5.0),
    #(2000, 7.0),
  ]
  assert polar.buckets(samples, 2000, 1000)
    == [
      polar.Bucket(age_ms: 1500, lo: 1.0, hi: 4.0, mean: 2.5, count: 2),
      polar.Bucket(age_ms: 500, lo: 3.0, hi: 7.0, mean: 5.0, count: 3),
    ]
  assert polar.buckets([], 0, 1000) == []
}
