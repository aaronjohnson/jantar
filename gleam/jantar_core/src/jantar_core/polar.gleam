//// The maths of hud's polar dials, without any drawing.
////
//// A dial is a polar clock: the angle is time, with "now" at 12 o'clock and
//// older samples trailing anticlockwise, wrapping every `period` (so a 30 min
//// window on a 10 min period goes round three times: three "laps"). The
//// radius is the value, mapped onto a ring between an inner radius r0 and an
//// outer radius r1, on a linear or a log scale. A "mirrored" dial puts zero on
//// the middle ring and plots positive values outward and negative inward
//// (power: charging vs discharging; net: download vs upload).
////
//// Angles are in radians in screen coordinates (y grows downward), so 12
//// o'clock is -pi/2 and "anticlockwise on screen" means decreasing angle.
//// Ages come from real timestamps (now - t), so irregular sampling plots in
//// the right place.

import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}

@external(erlang, "math", "pi")
fn pi() -> Float

@external(erlang, "math", "log10")
fn log10(x: Float) -> Float

/// How values map to 0..1 across the ring.
pub type Scale {
  /// lo..hi linearly.
  Linear(lo: Float, hi: Float)
  /// 10^lo_exp..10^hi_exp logarithmically, by magnitude (sign is ignored, and
  /// zero has no position: it isn't drawn).
  Log(lo_exp: Float, hi_exp: Float)
}

pub type Dial {
  Dial(scale: Scale, mirrored: Bool, window_ms: Int, period_ms: Int)
}

/// A dial showing `window_ms` of history, one lap per `period_ms` (None: the
/// whole window is one lap).
pub fn dial(
  scale scale: Scale,
  mirrored mirrored: Bool,
  window_ms window_ms: Int,
  period_ms period_ms: Option(Int),
) -> Dial {
  let period = case period_ms {
    Some(p) if p > 0 -> p
    _ -> window_ms
  }
  Dial(
    scale: scale,
    mirrored: mirrored,
    window_ms: window_ms,
    period_ms: period,
  )
}

/// How many times the window wraps round the dial, at least 1.
pub fn laps(d: Dial) -> Int {
  int.max(
    1,
    float.round(int.to_float(d.window_ms) /. int.to_float(d.period_ms)),
  )
}

// ------------------------------------------------------------------ value -> radius

/// How far out a value sits, 0..1 (clamped). For a mirrored linear dial this
/// is the magnitude against the larger of |lo| and |hi|.
pub fn reach(d: Dial, v: Float) -> Float {
  let f = case d.scale, d.mirrored {
    Log(lo, hi), _ -> {
      let m = float.absolute_value(v)
      case m <=. 0.0 {
        True -> 0.0
        False -> { log10(m) -. lo } /. { hi -. lo }
      }
    }
    Linear(lo, hi), True ->
      float.absolute_value(v)
      /. float.max(float.absolute_value(lo), float.absolute_value(hi))
    Linear(lo, hi), False -> { v -. lo } /. { hi -. lo }
  }
  float.clamp(f, min: 0.0, max: 1.0)
}

/// The radius for a value, between r0 (inner) and r1 (outer). Mirrored dials
/// grow from the zero ring outward for v >= 0 and inward for v < 0.
pub fn radius(d: Dial, v: Float, r0: Float, r1: Float) -> Float {
  case d.mirrored {
    True -> {
      let mid = zero_ring(r0, r1)
      let sign = case v <. 0.0 {
        True -> -1.0
        False -> 1.0
      }
      mid +. sign *. reach(d, v) *. { r1 -. mid }
    }
    False -> r0 +. reach(d, v) *. { r1 -. r0 }
  }
}

/// The radius of a mirrored dial's zero ring: halfway between r0 and r1.
pub fn zero_ring(r0: Float, r1: Float) -> Float {
  { r0 +. r1 } /. 2.0
}

/// Whether a value is drawn at all: on a log scale, zero (idle) is not.
pub fn visible(d: Dial, v: Float) -> Bool {
  case d.scale {
    Log(..) -> reach(d, v) >. 0.0
    Linear(..) -> True
  }
}

// ------------------------------------------------------------------ time -> angle

/// The angle for a sample `age_ms` old: -pi/2 (12 o'clock) for now, moving
/// anticlockwise and wrapping every period.
pub fn angle(age_ms: Int, period_ms: Int) -> Float {
  let p = int.max(1, period_ms)
  let into_lap = int.to_float(int.max(0, age_ms) % p) /. int.to_float(p)
  0.0 -. pi() /. 2.0 -. into_lap *. 2.0 *. pi()
}

/// The lap a sample is on: 0 for the newest period, 1 for the one before...
pub fn lap(age_ms: Int, period_ms: Int) -> Int {
  int.max(0, age_ms) / int.max(1, period_ms)
}

/// Where a sample #(t_ms, value) lands at time `now_ms`, as #(radius, angle);
/// None if it isn't drawn (zero on a log scale).
pub fn place(
  d: Dial,
  now_ms: Int,
  sample: #(Int, Float),
  r0: Float,
  r1: Float,
) -> Option(#(Float, Float)) {
  let #(t, v) = sample
  case visible(d, v) {
    False -> None
    True -> Some(#(radius(d, v, r0, r1), angle(now_ms - t, d.period_ms)))
  }
}

/// Spacing of the rim ticks: every 5 min on long laps (>= 20 min), every
/// minute on laps of 4 min or more, else every 30 s.
pub fn tick_ms(period_ms: Int) -> Int {
  case period_ms {
    p if p >= 1_200_000 -> 300_000
    p if p >= 240_000 -> 60_000
    _ -> 30_000
  }
}

// ------------------------------------------------------------------ scaling and fading

/// Widen lo..hi to take in every value, rounding out to a multiple of `step`
/// (hud's `auto=True`). hi always ends up above lo.
pub fn auto_range(
  lo: Float,
  hi: Float,
  step: Float,
  values: List(Float),
) -> #(Float, Float) {
  let #(lo, hi) = case values {
    [] -> #(lo, hi)
    [first, ..] -> {
      let #(mn, mx) = fold_min_max(values, #(first, first))
      let hi = case mx >. hi {
        True -> float.ceiling(mx /. step) *. step
        False -> hi
      }
      let lo = case mn <. lo {
        True -> float.floor(mn /. step) *. step
        False -> lo
      }
      #(lo, hi)
    }
  }
  #(lo, float.max(hi, lo +. 1.0e-9))
}

fn fold_min_max(values: List(Float), acc: #(Float, Float)) -> #(Float, Float) {
  case values {
    [] -> acc
    [v, ..rest] ->
      fold_min_max(rest, #(float.min(acc.0, v), float.max(acc.1, v)))
  }
}

/// A fixed pseudo-random 0..1 for a sample's sequence number, so thinning old
/// dots picks the same ones every frame (no flicker).
pub fn keep(seq: Int) -> Float {
  int.to_float(int.bitwise_and(seq * 2_654_435_761, 0xFFFF)) /. 65_536.0
}

/// How a sample is styled by age: the newest few bold, recent ones plain,
/// older ones dim.
pub type Fade {
  Newest
  Recent
  Old
}

/// `rank` counts the samples newer than this one (0 = newest); `age_fraction`
/// is its age as a share of the window, 0..1.
pub fn fade(rank: Int, age_fraction: Float) -> Fade {
  case rank < 3, age_fraction <=. 0.4 {
    True, _ -> Newest
    False, True -> Recent
    False, False -> Old
  }
}

/// Whether to skip an older dot: the older it is, the sparser (up to 70% of
/// dots dropped at the end of the window). The newest three always show.
pub fn thinned(rank: Int, age_fraction: Float, seq: Int) -> Bool {
  rank >= 3
  && keep(seq)
  >. 1.0 -. 0.7 *. sqrt(float.clamp(age_fraction, min: 0.0, max: 1.0))
}

fn sqrt(x: Float) -> Float {
  case float.square_root(x) {
    Ok(r) -> r
    Error(_) -> 0.0
  }
}

// ------------------------------------------------------------------ dense series

/// A run of samples summarised for drawing: when a dial has more samples
/// than pixels to put them on, it draws one bucket per few pixels of arc as a
/// min..max band with a line through the mean, instead of a blur of dots.
pub type Bucket {
  Bucket(age_ms: Int, lo: Float, hi: Float, mean: Float, count: Int)
}

/// Whether a series is too dense for distinct dots: more samples per lap than
/// `dots_per_lap` (e.g. a third of the lap's length in pixels).
pub fn dense(samples: Int, laps: Int, dots_per_lap: Float) -> Bool {
  int.to_float(samples) /. int.to_float(int.max(1, laps)) >. dots_per_lap
}

/// Group samples #(t_ms, value), oldest first, into buckets `bucket_ms` wide
/// by age at `now_ms`. Returns buckets oldest first; `age_ms` is the middle
/// of the bucket's age range.
pub fn buckets(
  samples: List(#(Int, Float)),
  now_ms: Int,
  bucket_ms: Int,
) -> List(Bucket) {
  let width = int.max(1, bucket_ms)
  bucket_loop(samples, now_ms, width, None, [])
}

type Open {
  Open(index: Int, lo: Float, hi: Float, sum: Float, count: Int)
}

fn bucket_loop(
  samples: List(#(Int, Float)),
  now: Int,
  width: Int,
  open: Option(Open),
  done: List(Bucket),
) -> List(Bucket) {
  case samples, open {
    [], None -> reverse(done)
    [], Some(o) -> reverse([close(o, width), ..done])
    [#(t, v), ..rest], _ -> {
      let index = int.max(0, now - t) / width
      case open {
        Some(o) if o.index == index ->
          bucket_loop(
            rest,
            now,
            width,
            Some(Open(
              index,
              float.min(o.lo, v),
              float.max(o.hi, v),
              o.sum +. v,
              o.count + 1,
            )),
            done,
          )
        Some(o) ->
          bucket_loop(rest, now, width, Some(Open(index, v, v, v, 1)), [
            close(o, width),
            ..done
          ])
        None ->
          bucket_loop(rest, now, width, Some(Open(index, v, v, v, 1)), done)
      }
    }
  }
}

fn close(o: Open, width: Int) -> Bucket {
  Bucket(
    age_ms: o.index * width + width / 2,
    lo: o.lo,
    hi: o.hi,
    mean: o.sum /. int.to_float(o.count),
    count: o.count,
  )
}

fn reverse(xs: List(a)) -> List(a) {
  do_reverse(xs, [])
}

fn do_reverse(xs: List(a), acc: List(a)) -> List(a) {
  case xs {
    [] -> acc
    [x, ..rest] -> do_reverse(rest, [x, ..acc])
  }
}
