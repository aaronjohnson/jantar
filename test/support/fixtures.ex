defmodule Jantar.Fixtures do
  @moduledoc """
  Test helpers for the recorded samples in test/fixtures/capture (see
  tools/capture-fixtures.sh) and for building small synthetic sysfs trees.
  """

  @capture Path.expand("../fixtures/capture", __DIR__)

  @doc "The directory of a recorded snapshot, \"t0\" or \"t1\"."
  def snapshot(name), do: Path.join(@capture, name)

  @doc "What hud itself computed from the snapshots (tools/hud_oracle.py)."
  def expected do
    @capture |> Path.join("hud_expected.json") |> File.read!() |> JSON.decode!()
  end

  @doc "Copy a snapshot over `dir` (symlinks stay symlinks), replacing files that exist."
  def load_snapshot(dir, name) do
    File.cp_r!(snapshot(name), dir, on_conflict: fn _, _ -> true end)
    dir
  end

  @doc "Write `files` (`%{\"/proc/uptime\" => \"5600.0 1.0\"}`) under `dir`."
  def write_tree(dir, files) do
    for {path, contents} <- files do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end

    dir
  end

  @doc "True when a and b agree to a relative tolerance."
  def close?(a, b, tolerance \\ 1.0e-9) do
    abs(a - b) <= tolerance * max(1.0, abs(b))
  end
end
