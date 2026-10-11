//// Entry point for `gleam test`: gleeunit runs every public function whose
//// name ends in `_test`, in every module under test/.

import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}
