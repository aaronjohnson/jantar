defmodule Jantar.SmoothTest do
  @moduledoc "Smoothing a dense trace's buckets (Frame.smooth/2)."
  use ExUnit.Case, async: true

  alias Jantar.Frame

  defp b(age, v, count \\ 1), do: {:bucket, age, v, v, v / 1, count}

  test "the line follows the mean over the span, the band its min and max" do
    # Alternating 0 and 10 every 250 ms: a jagged line.
    buckets = for i <- 0..8, do: b(2000 - i * 250, if(rem(i, 2) == 0, do: 0, else: 10))
    smoothed = Frame.smooth(buckets, 1000)

    {:bucket, 1000, lo, hi, mean, 1} = Enum.at(smoothed, 4)
    # Neighbours within 500 ms: ages 1500..500, values 0 10 0 10 0.
    assert {lo, hi} == {0, 10}
    assert_in_delta mean, 4.0, 1.0e-9
    # Ages and counts kept.
    assert Enum.map(smoothed, &elem(&1, 1)) == Enum.map(buckets, &elem(&1, 1))
  end

  test "weighted by samples, and gaps longer than the span stay apart" do
    [x, y, z] = Frame.smooth([b(10_000, 4.0, 3), b(9_800, 0.0, 1), b(1_000, 100.0)], 1000)
    assert_in_delta elem(x, 4), 3.0, 1.0e-9
    assert_in_delta elem(y, 4), 3.0, 1.0e-9
    # 8.8 s away: untouched.
    assert z == b(1_000, 100.0)
  end

  test "a span of one bucket changes nothing" do
    buckets = for i <- 0..5, do: b(6000 - i * 1000, i * 1.0)
    assert Frame.smooth(buckets, 1000) == buckets
    assert Frame.smooth([], 1000) == []
  end
end
