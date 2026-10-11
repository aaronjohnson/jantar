import gleam/option.{None, Some}
import gleeunit/should
import jantar_core/archive.{Row, Spec, Step}

const minute = Spec(step_ms: 60_000, keep_ms: 86_400_000)

pub fn steps_align_to_the_clock_test() {
  archive.step_start(minute, 125_000) |> should.equal(120_000)
  archive.step_start(minute, 120_000) |> should.equal(120_000)
  archive.step_start(minute, 59_999) |> should.equal(0)
}

pub fn samples_in_one_step_fold_together_test() {
  let #(row, open) = archive.add(minute, None, 120_500, 2.0)
  row |> should.equal(None)
  let #(row, open) = archive.add(minute, open, 130_000, 6.0)
  row |> should.equal(None)
  let #(row, open) = archive.add(minute, open, 179_999, 1.0)
  row |> should.equal(None)
  open |> should.equal(Some(Step(120_000, 1.0, 6.0, 9.0, 3)))
}

pub fn a_new_step_hands_back_the_finished_row_test() {
  let #(_, open) = archive.add(minute, None, 120_500, 2.0)
  let #(_, open) = archive.add(minute, open, 130_000, 4.0)
  let #(row, open) = archive.add(minute, open, 245_000, 10.0)
  row |> should.equal(Some(Row(120_000, 2.0, 3.0, 4.0, 2)))
  open |> should.equal(Some(Step(240_000, 10.0, 10.0, 10.0, 1)))
}

pub fn a_sample_from_before_the_open_step_is_ignored_test() {
  let #(_, open) = archive.add(minute, None, 245_000, 10.0)
  let #(row, open2) = archive.add(minute, open, 130_000, 99.0)
  row |> should.equal(None)
  open2 |> should.equal(open)
}

pub fn retention_test() {
  archive.expired_before(minute, 90_000_000) |> should.equal(3_600_000)
}
