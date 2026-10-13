defmodule Jantar.NpuExamplesTest do
  @moduledoc """
  The NPU example runner against a stand-in `npu-example` script: the
  catalogue, a run's progress and results, stopping one, and a failing
  command. No NPU needed.
  """
  use ExUnit.Case, async: false

  alias Jantar.{History, NpuExamples}

  @moduletag :tmp_dir

  # A stand-in for npu-example: `list --json` prints a catalogue; `fast`
  # runs two variants; `slow` hangs until killed; `broken` fails at once.
  @script ~S"""
  #!/bin/sh
  case "$1" in
    list) echo '[{"name": "fast", "title": "Fast"}, {"name": "slow", "title": "Slow"}, {"name": "broken", "title": "Broken"}]' ;;
    fast)
      echo '{"event": "start", "example": "fast", "variants": ["a", "b"]}'
      echo 'a warning from some library'
      echo '{"event": "variant", "label": "a", "phase": "run"}'
      echo '{"event": "result", "label": "a", "latency_ms": 1.0, "device_ms": 0.5, "engines_us": {"DPU": 300, "Shave": 100}}'
      echo '{"event": "variant", "label": "b", "phase": "run"}'
      echo '{"event": "result", "label": "b", "latency_ms": 2.0, "device_ms": 1.0, "engines_us": {"DPU": 500, "DMA": 100}}'
      echo '{"event": "done", "example": "fast"}' ;;
    slow)
      echo '{"event": "start", "example": "slow", "variants": ["x"]}'
      echo '{"event": "variant", "label": "x", "phase": "run"}'
      exec sleep 600 ;;
    *) exit 3 ;;
  esac
  """

  setup %{tmp_dir: dir} do
    exe = Path.join(dir, "npu-example")
    File.write!(exe, @script)
    File.chmod!(exe, 0o755)
    name = :"runner_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {NpuExamples, exe: exe, name: name, list_delay: 0, state_dir: dir, seconds: 1}
      )

    wait(fn c -> c.catalogue != [] end)
    %{name: name, pid: pid, dir: dir}
  end

  defp current, do: History.current(:npu_examples)

  # Poll the published state until `ok?` holds (the runner is asynchronous).
  defp wait(ok?, tries \\ 200) do
    c = current()

    cond do
      c && ok?.(c) -> c
      tries == 0 -> flunk("never reached: #{inspect(c)}")
      true -> Process.sleep(10) && wait(ok?, tries - 1)
    end
  end

  test "reads the catalogue, then runs an example to its results", %{name: name, dir: dir} do
    assert Enum.map(current().catalogue, & &1.name) == ["fast", "slow", "broken"]

    NpuExamples.run("fast", name)
    c = wait(&(&1.state == :idle and Map.has_key?(&1.results, "fast")))
    r = c.results["fast"]
    assert r.ok
    assert Enum.map(r.variants, & &1.label) == ["a", "b"]
    # Engine time over both variants: DPU 800, Shave 100, DMA 100 µs.
    assert_in_delta r.engines["DPU"], 0.8, 1.0e-9
    assert_in_delta r.engines["Shave"], 0.1, 1.0e-9

    # Marked on the dials: a start and an end.
    marks = for {_, code} <- History.samples({:event, :npu_example}), do: code
    assert Enum.take(marks, -2) == [20, 21]

    # Kept for the next start.
    assert File.exists?(Path.join(dir, "npu_examples.etf"))
  end

  test "stop kills a running example", %{name: name} do
    NpuExamples.run("slow", name)
    c = wait(&(&1.state == :running and &1.label == "x"))
    assert c.index == 1 and c.count == 1

    # A second request while one runs is ignored.
    NpuExamples.run("fast", name)
    NpuExamples.stop(name)
    c = wait(&(&1.state == :idle))
    assert c.error == "stopped"
    refute Map.has_key?(c.results, "fast")
  end

  test "a failing example, and an unknown one, leave it idle", %{name: name} do
    NpuExamples.run("nonexistent", name)
    NpuExamples.run("broken", name)
    c = wait(&(&1.state == :idle and &1.error != nil))
    assert c.error == "exit 3"
    refute Map.has_key?(c.results, "broken")
  end
end
