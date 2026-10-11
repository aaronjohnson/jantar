defmodule Jantar.HistorySaveTest do
  @moduledoc """
  History saved on shutdown and loaded on start. Restarts the application's
  History, so not async (sync modules run after all the async ones).
  """
  use ExUnit.Case, async: false

  alias Jantar.History

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      Application.delete_env(:jantar, :state_dir)
      restart_history()
    end)
  end

  defp restart_history do
    :ok = Supervisor.terminate_child(Jantar.Supervisor, History)
    {:ok, _} = Supervisor.restart_child(Jantar.Supervisor, History)
  end

  test "samples survive a restart, with their times carried over", %{tmp_dir: dir} do
    # History reads state_dir when it starts.
    Application.put_env(:jantar, :state_dir, dir)
    restart_history()

    series = {:saved, System.unique_integer([:positive])}
    now = System.monotonic_time(:millisecond)
    History.declare(series, 60_000)
    for {dt, v} <- [{-3000, 1.0}, {-2000, nil}, {-1000, 3}], do: History.push(series, now + dt, v)

    # Stopping saves, starting again loads.
    restart_history()

    assert File.exists?(Path.join(dir, "history.etf"))
    assert %{size: 3, total: 3, window_ms: 60_000} = History.info(series)
    restored = History.samples(series)
    assert Enum.map(restored, &elem(&1, 1)) == [1.0, nil, 3]

    # Saved as wall-clock time and converted back: the same moments, give or
    # take the few ms between reading the two clocks.
    for {{t, _}, dt} <- Enum.zip(restored, [-3000, -2000, -1000]),
        do: assert(abs(t - (now + dt)) < 50)

    # The time it was down is marked: same boot, so a service restart (11).
    assert [{down, -11}, {up, 11}] = History.samples({:event, :restart}) |> Enum.take(-2)
    assert down <= up

    # The next push carries on the sequence.
    History.push(series, now, 4.0)
    assert History.last(series) == {now, 4.0}
  end

  test "a damaged file is ignored, not fatal", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "history.etf"), "not a term")
    Application.put_env(:jantar, :state_dir, dir)

    ExUnit.CaptureLog.capture_log(fn -> restart_history() end)

    assert Process.whereis(History)
  end
end
