//// Test helpers: read the captured /proc and /sys samples shared with the
//// Elixir tests (test/fixtures/capture at the repository root), and compare
//// floats with a tolerance.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/float

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// The repository's fixture directory, relative to gleam/jantar_core (where
/// `gleam test` runs).
pub const root = "../../test/fixtures/capture"

/// The contents of a captured file, e.g. read("t0", "/proc/stat").
pub fn read(snapshot: String, path: String) -> String {
  let assert Ok(bits) = read_file(root <> "/" <> snapshot <> path)
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

/// True when a and b agree to within 1e-9, relative to their size.
pub fn close(a: Float, b: Float) -> Bool {
  float.loosely_equals(
    a,
    b,
    tolerating: 1.0e-9 *. float.max(1.0, float.absolute_value(b)),
  )
}
