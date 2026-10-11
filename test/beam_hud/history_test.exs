defmodule BeamHud.HistoryTest do
  @moduledoc """
  History is the application's (started with the app, sensors off in test), so
  each test uses its own series names.
  """
  use ExUnit.Case, async: true

  alias BeamHud.History

  defp unique(name), do: {name, System.unique_integer([:positive])}

  test "samples keep their own timestamps, oldest first" do
    s = unique(:t)
    History.declare(s, 10_000)
    for {t, v} <- [{0, 1.0}, {250, 2.0}, {1700, nil}, {1800, 4}], do: History.push(s, t, v)

    # Irregular times and gaps (nil) are kept as given.
    assert History.samples(s) == [{0, 1.0}, {250, 2.0}, {1700, nil}, {1800, 4}]
    assert History.last(s) == {1800, 4}
    assert %{size: 4, total: 4, window_ms: 10_000} = History.info(s)
  end

  test "keeps a time window: faster sampling holds more points" do
    slow = unique(:slow)
    fast = unique(:fast)
    History.declare(slow, 10_000)
    History.declare(fast, 10_000)
    for t <- 0..60_000//1000, do: History.push(slow, t, 0)
    for t <- 0..60_000//250, do: History.push(fast, t, 0)

    # Samples from the last 10 s, inclusive.
    assert History.info(slow).size == 11
    assert History.info(fast).size == 41
    assert hd(History.samples(fast)) == {50_000, 0}
    # Every push counted, for stable sample identities.
    assert History.info(fast).total == 241
  end

  test "caps the number of points" do
    s = unique(:cap)
    History.declare(s, 3_600_000, 5)
    for t <- 1..20, do: History.push(s, t, t)
    assert Enum.map(History.samples(s), &elem(&1, 0)) == [16, 17, 18, 19, 20]
  end

  test "the global cap (config :max_points) bounds every series" do
    s = unique(:huge)
    History.declare(s, 3_600_000, 1_000_000)
    assert History.info(s).max_points == Application.get_env(:beam_hud, :max_points)
  end

  test "declaring again keeps the samples and changes the window" do
    s = unique(:redeclare)
    History.declare(s, 60_000)
    for t <- 0..10, do: History.push(s, t * 1000, t)
    History.declare(s, 5_000)
    assert History.info(s).size == 11
    History.push(s, 11_000, 11)
    assert Enum.map(History.samples(s), &elem(&1, 1)) == [6, 7, 8, 9, 10, 11]
  end

  test "an undeclared series gets the default window" do
    s = unique(:undeclared)
    History.push(s, 0, 1)
    assert History.info(s).window_ms == 30 * 60_000
    assert s in History.series()
  end

  test "series are separate even when names are similar" do
    a = {:gpu, "gt0-rc"} |> then(fn {k, n} -> {k, n <> "#{System.unique_integer()}"} end)
    b = {:gpu, elem(a, 1) <> "x"}
    History.push(a, 0, 1)
    History.push(b, 0, 2)
    assert History.samples(a) == [{0, 1}]
    assert History.samples(b) == [{0, 2}]
  end

  test "sensor status and current values" do
    name = :"sensor_#{System.unique_integer([:positive])}"
    assert History.sensor(name) == nil
    History.put_sensor(name, :ok, %{x: 1}, 42)
    assert History.sensor(name) == %{status: :ok, current: %{x: 1}, t_ms: 42}
    assert History.current(name) == %{x: 1}
  end

  test "readers don't need the History process: the tables are readable by anyone" do
    s = unique(:read)
    History.push(s, 5, 1)
    assert Task.async(fn -> History.samples(s) end) |> Task.await() == [{5, 1}]
  end
end
