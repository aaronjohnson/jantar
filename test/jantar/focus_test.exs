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
    assert Ticker.keys("n", @overview) == %{@overview | focus: "NETWORK"}
    assert Ticker.keys("n1", @overview) == %{@overview | focus: "NETWORK", window: 60_000}
    assert Ticker.keys("n3", @overview).window == 1_800_000
    # Zoomed, 1 2 3 leave the overview's scale alone.
    assert Ticker.keys("3n1", @overview).scale == :month
  end

  test "keys: Esc, 0, q or the same letter go back; arrow keys don't" do
    zoomed = %{@overview | focus: "NETWORK", window: 60_000}
    assert Ticker.keys(<<27>>, zoomed).focus == nil
    assert Ticker.keys("0", zoomed).focus == nil
    assert Ticker.keys("q", zoomed).focus == nil
    assert Ticker.keys("n", zoomed).focus == nil
    assert Ticker.keys("\e[A", zoomed) == zoomed
    # Another section's letter moves the zoom there.
    assert Ticker.keys("c", zoomed) == %{zoomed | focus: "CPU", window: 300_000}
  end

  test "every zoom key names a section the frame knows" do
    for k <- ~c"cgmtpn",
        do: assert(Ticker.keys(<<k>>, @overview).focus in Frame.section_titles())
  end

  test "a focused frame draws that section's panels only, in its window" do
    snap = Frame.window(Frame.Demo.snapshot(), 60_000)
    {_, meta} = Frame.build(snap, width: 720, height: 480, focus: "NETWORK", theme: :dark)
    assert Enum.sort(meta.sensors) == [:link, :net, :wifi]

    for {name, s} <- snap.series, not match?({:event, _}, name) do
      assert s.window_ms == 60_000
      assert Enum.all?(s.samples, fn {t, _} -> snap.now - t <= 60_000 end)
    end

    {_, overview} = Frame.build(Frame.Demo.snapshot(), width: 720, height: 480, theme: :dark)
    assert length(overview.sensors) > 10
  end
end
