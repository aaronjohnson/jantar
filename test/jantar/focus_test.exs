defmodule Jantar.FocusTest do
  @moduledoc """
  Zooming in on one section: the keys that do it (`Ticker.keys/2`), and the
  frame it gives (`Frame.window/2`, `Frame.build/2`'s `:focus`).
  """
  use ExUnit.Case, async: true

  alias Jantar.Display.Ticker
  alias Jantar.Frame
  alias Jantar.History

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

  test "on the NPU screen, j k pick an example, r and Enter run it, x stops" do
    npu = %{@overview | focus: "NPU"} |> Map.put(:pick, 0)
    assert Ticker.keys("jj", npu).pick == 2
    assert Ticker.keys("k", npu).pick == -1
    assert Ticker.keys("jr", npu).command == {:run, 1}
    assert Ticker.keys("\r", npu).command == {:run, 0}
    assert Ticker.keys("x", npu).command == :stop
    # Elsewhere those letters do nothing.
    assert Ticker.keys("jrx", %{@overview | focus: "CPU"}) == %{@overview | focus: "CPU"}
  end

  test "the NPU screen lists the examples only when the runner is there" do
    snap = Frame.Demo.snapshot()

    {with_ex, _} =
      Frame.build(snap, width: 1440, height: 960, focus: "NPU", theme: :dark, pick: 7)

    assert with_ex =~ "EXAMPLES" and with_ex =~ "running 8/13"

    sensors = Map.put(snap.sensors, :npu_examples, nil)

    {without, _} =
      Frame.build(%{snap | sensors: sensors},
        width: 1440,
        height: 960,
        focus: "NPU",
        theme: :dark
      )

    refute without =~ "EXAMPLES"

    idle = %{
      snap.sensors.npu_examples
      | state: :idle,
        catalogue: [],
        results: %{},
        error: "no examples (exit 1)"
    }

    {bin, _} =
      Frame.build(%{snap | sensors: %{snap.sensors | npu_examples: idle}},
        width: 1440,
        height: 960,
        focus: "NPU",
        theme: :dark
      )

    assert bin =~ "no examples"
  end

  test "a brief counter read error keeps the DMA dial, saying so" do
    History.put_sensor(
      :npu_counters,
      {:unavailable, {:npu_port, "zetMetricStreamerReadData NOC failed"}},
      nil,
      0
    )

    assert Frame.snapshot().sensors.npu_counters == %{
             streaming: false,
             retrying: "zetMetricStreamerReadData NOC failed"
           }

    History.put_sensor(:npu_counters, {:unavailable, :disabled}, nil, 0)
    assert Frame.snapshot().sensors.npu_counters == nil

    snap = Frame.Demo.snapshot()
    sensors = %{snap.sensors | npu_counters: %{streaming: false, retrying: "x"}}

    {bin, _} =
      Frame.build(%{snap | sensors: sensors},
        width: 1440,
        height: 960,
        focus: "NPU",
        theme: :dark
      )

    assert bin =~ "counters lost, retrying"
  end

  test "legend words take the colours they name" do
    {bin, _} =
      Frame.build(Frame.Demo.snapshot(), width: 1440, height: 960, focus: "NPU", theme: :dark)

    c = Jantar.Theme.palette(:dark)
    # "green DMA" is a text part of its own, in green; "magenta RISC-V" in magenta.
    assert :binary.match(bin, "green DMA") != :nomatch

    for {word, colour} <- [
          {"green DMA", c.green},
          {"magenta RISC-V", c.magenta},
          {"cyan SHAVE", c.cyan}
        ] do
      assert :binary.match(bin, <<colour::32-little, byte_size(word)::16-little, word::binary>>) !=
               :nomatch
    end
  end

  test "the examples list scrolls to the pick and says where it's used" do
    snap = Frame.Demo.snapshot()

    build = fn pick ->
      Frame.build(snap, width: 1440, height: 960, focus: "NPU", theme: :dark, pick: pick)
      |> elem(0)
    end

    top = build.(0)
    assert top =~ "Matrix work" and top =~ "used in"
    refute top =~ "Search embeddings"

    bottom = build.(10)
    assert bottom =~ "Search embeddings" and bottom =~ "semantic search"
    refute bottom =~ "Matrix work"
  end
end
