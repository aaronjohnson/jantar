defmodule Jantar.FocusTest do
  @moduledoc """
  Zooming in on one section: the keys that do it (`Ticker.keys/2`), and the
  frame it gives (`Frame.window/2`, `Frame.build/2`'s `:focus`).
  """
  use ExUnit.Case, async: true

  alias Jantar.Display.Ticker
  alias Jantar.Frame

  @overview %{scale: :live, focus: nil, window: 300_000}

  test "keys: 1 2 3 pick the scale in the overview, the window when zoomed" do
    assert Ticker.keys("2", @overview).scale == :day
    assert Ticker.keys("l", @overview) == %{@overview | focus: "LINKS"}
    assert Ticker.keys("l1", @overview) == %{@overview | focus: "LINKS", window: 60_000}
    assert Ticker.keys("l3", @overview).window == 1_800_000
    # Zoomed, 1 2 3 leave the overview's scale alone.
    assert Ticker.keys("3l1", @overview).scale == :month
  end

  test "keys: Esc, 0, q or the same letter go back; arrow keys don't" do
    zoomed = %{@overview | focus: "LINKS", window: 60_000}
    assert Ticker.keys(<<27>>, zoomed).focus == nil
    assert Ticker.keys("0", zoomed).focus == nil
    assert Ticker.keys("q", zoomed).focus == nil
    assert Ticker.keys("l", zoomed).focus == nil
    assert Ticker.keys("\e[A", zoomed) == zoomed
    # Another section's letter moves the zoom there.
    assert Ticker.keys("c", zoomed) == %{zoomed | focus: "CPU", window: 300_000}
  end

  test "every zoom key names a section the frame knows" do
    for k <- ~c"cgtnpml",
        do: assert(Ticker.keys(<<k>>, @overview).focus in Frame.section_titles())
  end

  test "a focused frame draws that section's panels only, in its window" do
    snap = Frame.window(Frame.Demo.snapshot(), 60_000)
    {_, meta} = Frame.build(snap, width: 720, height: 480, focus: "LINKS", theme: :dark)
    assert Enum.sort(meta.sensors) == [:link, :net, :wifi]

    for {name, s} <- snap.series, not match?({:event, _}, name) do
      assert s.window_ms == 60_000
      assert Enum.all?(s.samples, fn {t, _} -> snap.now - t <= 60_000 end)
    end

    {_, overview} = Frame.build(Frame.Demo.snapshot(), width: 720, height: 480, theme: :dark)
    assert length(overview.sensors) > 10
  end

  test "GPU shares the CPU's row in the overview but zooms on its own" do
    sensors = fn focus ->
      {_, meta} =
        Frame.build(Frame.Demo.snapshot(), width: 720, height: 480, focus: focus, theme: :dark)

      Enum.sort(meta.sensors)
    end

    gpu = sensors.("GPU")
    npu = sensors.("NPU")
    assert gpu != [] and npu != []
    assert MapSet.disjoint?(MapSet.new(gpu), MapSet.new(npu))
  end

  test "the NPU screen draws its pipeline whatever the counters say" do
    snap = Frame.Demo.snapshot()
    {full, _} = Frame.build(snap, width: 1440, height: 960, focus: "NPU", theme: :dark)
    {gpu, _} = Frame.build(snap, width: 1440, height: 960, focus: "GPU", theme: :dark)
    assert full =~ "HOW A JOB RUNS"
    refute gpu =~ "HOW A JOB RUNS"

    for counters <- [
          nil,
          %{streaming: false},
          %{snap.sensors.npu_counters | dma: nil, riscv: nil, shave: nil, compute: nil}
        ] do
      sensors = Map.put(snap.sensors, :npu_counters, counters)

      {bin, _} =
        Frame.build(%{snap | sensors: sensors},
          width: 1440,
          height: 960,
          focus: "NPU",
          theme: :light
        )

      assert bin =~ "SHAVE"
    end
  end
end
