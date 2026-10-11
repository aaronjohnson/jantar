defmodule Jantar.SensorTest do
  @moduledoc """
  The generic sensor process, driven by a fake source whose behaviour the test
  controls through files in a temporary directory.
  """
  use ExUnit.Case, async: true

  alias Jantar.{History, Sensor}

  @moduletag :tmp_dir

  defmodule FakeSource do
    @moduledoc false
    @behaviour Jantar.Sensor

    # Available when <dir>/present exists; samples <dir>/value (a number);
    # raises if <dir>/raise exists.
    def defaults, do: [interval: 20]

    def init(opts) do
      dir = opts[:dir]

      if File.exists?(Path.join(dir, "present")) do
        {:ok, %{dir: dir, series: opts[:series]}, [{opts[:series], 60_000}]}
      else
        {:unavailable, :not_present}
      end
    end

    def sample(state, _now) do
      if File.exists?(Path.join(state.dir, "raise")), do: raise("boom")

      case File.read(Path.join(state.dir, "value")) do
        {:ok, text} ->
          v = String.to_integer(String.trim(text))
          {:ok, [{state.series, v}], %{value: v}, state}

        {:error, _} ->
          {:unavailable, :no_value, state}
      end
    end
  end

  defp start(dir, opts \\ []) do
    id = System.unique_integer([:positive])
    name = :"fake_#{id}"
    series = {:fake, id}

    pid =
      start_supervised!(
        {Sensor,
         [
           module: FakeSource,
           name: name,
           report_as: name,
           dir: dir,
           series: series,
           first_backoff: 20
         ] ++ opts}
      )

    %{pid: pid, name: name, series: series}
  end

  defp put(dir, file, contents \\ ""), do: File.write!(Path.join(dir, file), contents)

  # Poll until `fun` returns truthy (sensors run on their own schedule).
  defp eventually(fun, tries \\ 100) do
    case fun.() do
      result when result in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  test "samples on its interval into History, with timestamps", %{tmp_dir: dir} do
    put(dir, "present")
    put(dir, "value", "7")
    s = start(dir)

    assert eventually(fn -> History.info(s.series) && History.info(s.series).size >= 3 end)
    samples = History.samples(s.series)
    times = Enum.map(samples, &elem(&1, 0))
    assert Enum.all?(samples, &(elem(&1, 1) == 7))
    # Monotonic timestamps, roughly 20 ms apart.
    assert times == Enum.sort(times)
    assert History.info(s.series).window_ms == 60_000
    assert %{status: :ok, current: %{value: 7}} = History.sensor(s.name)
  end

  test "a missing source is reported, not crashed, and picked up when it appears",
       %{tmp_dir: dir} do
    s = start(dir)
    assert eventually(fn -> History.sensor(s.name) end).status == {:unavailable, :not_present}
    assert Process.alive?(s.pid)

    put(dir, "present")
    put(dir, "value", "3")
    assert eventually(fn -> History.sensor(s.name).status == :ok end)
    assert History.last(s.series) |> elem(1) == 3
  end

  @tag :capture_log
  test "a source that raises is unavailable; the process survives", %{tmp_dir: dir} do
    put(dir, "present")
    put(dir, "value", "1")
    put(dir, "raise")

    s = start(dir)
    assert {:unavailable, {:raised, "boom"}} = eventually(fn -> History.sensor(s.name) end).status
    assert Process.alive?(s.pid)

    # Recovers once the problem goes away (after the backoff).
    File.rm!(Path.join(dir, "raise"))
    assert eventually(fn -> History.sensor(s.name).status == :ok end)
  end

  test "adaptive: backs off while flat, speeds up when the value jumps", %{tmp_dir: dir} do
    put(dir, "present")
    put(dir, "value", "5")
    s = start(dir, adaptive: true, max_interval: 80)

    # Flat: the interval grows from 20 towards 80 ms.
    assert eventually(fn -> Sensor.interval(s.name) == 80 end, 200)

    # A big step relative to the recent range: it halves.
    put(dir, "value", "500")
    assert eventually(fn -> Sensor.interval(s.name) < 80 end, 200)
  end

  test "without adaptive sampling the interval stays put", %{tmp_dir: dir} do
    put(dir, "present")
    put(dir, "value", "5")
    s = start(dir)
    eventually(fn -> History.info(s.series) && History.info(s.series).size >= 5 end)
    assert Sensor.interval(s.name) == 20
  end

  test "options: defaults, then app config, then start options" do
    Application.put_env(:jantar, FakeSource, interval: 99, extra: :config)
    on_exit(fn -> Application.delete_env(:jantar, FakeSource) end)

    opts = Sensor.options(FakeSource, extra: :given)
    assert opts[:interval] == 99
    assert opts[:extra] == :given
    assert opts[:root] == "/"
  end

  test "names" do
    assert Sensor.name_of(Jantar.Sensors.CiRunner) == :ci_runner
    assert Sensor.name_of(Jantar.Sensors.Cpu) == :cpu
  end
end
