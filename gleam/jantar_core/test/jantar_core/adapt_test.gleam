//// Adaptive sampling: speed up on movement, back off when flat, stay within
//// the policy's bounds.

import jantar_core/adapt.{Policy}

// CPU load: 250 ms at most, 2 s at least, ignore steps under 2%.
const policy = Policy(min_ms: 250, max_ms: 2000, noise: 0.02)

pub fn too_few_samples_test() {
  assert adapt.next_interval([], 1000, policy) == 1000
  assert adapt.next_interval([0.1, 0.9], 1000, policy) == 1000
  // ...but still clamped into the bounds.
  assert adapt.next_interval([], 50, policy) == 250
}

pub fn flat_decays_to_max_test() {
  let flat = [0.1, 0.1, 0.1, 0.1]
  assert adapt.next_interval(flat, 1000, policy) == 1250
  // Repeated calls grow towards the max and stop there.
  assert adapt.next_interval(flat, 1900, policy) == 2000
  assert adapt.next_interval(flat, 2000, policy) == 2000
  // Jitter under the noise floor counts as flat.
  assert adapt.next_interval([0.1, 0.11, 0.1, 0.11], 1000, policy) == 1250
}

pub fn big_step_speeds_up_test() {
  // The latest step is the whole recent range: halve.
  assert adapt.next_interval([0.1, 0.1, 0.1, 0.8], 1000, policy) == 500
  // ...down to the minimum.
  assert adapt.next_interval([0.1, 0.1, 0.1, 0.8], 300, policy) == 250
}

pub fn moderate_step_holds_test() {
  // A step of 30% of the range: keep the interval.
  assert adapt.next_interval([0.0, 1.0, 0.5, 0.8], 1000, policy) == 1000
}

pub fn settling_grows_test() {
  // Moved a lot earlier, small step now (10% of range): grow.
  assert adapt.next_interval([0.0, 1.0, 0.5, 0.55], 1000, policy) == 1250
}
