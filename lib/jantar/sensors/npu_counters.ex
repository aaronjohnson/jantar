defmodule Jantar.Sensors.NpuCounters do
  @moduledoc """
  What the NPU is moving while it works: its network-on-chip counters from
  Level Zero (`Jantar.NpuPort`). There is no counter for the matrix engines
  themselves; data moved by DMA is the closest measure of how hard they are
  fed.

  Any Level Zero call wakes a suspended NPU, and an open streamer keeps it
  awake. So the streamer is opened only once the NPU is awake and its busy
  time (sysfs, which leaves it asleep) has moved, and closed as soon as busy
  time stops moving, so the NPU can suspend again. Nothing is read while it
  sleeps; the series have gaps there.

  Series, per second, 5 min: `{:npu, :dma}` (all NOC DMA traffic, probably
  bytes), `{:npu, :riscv}` and `{:npu, :shave}` (L2 cache traffic of the
  RISC-V control cores and the SHAVE vector cores). The DPU and NCE clocks
  are in the current values.

  Options: `:enabled` (false turns it off), `:driver_path` (where the Level
  Zero loader finds libze_intel_npu), `:exe` and `:port_module` (tests).
  """
  @behaviour Jantar.Sensor
  alias Jantar.Sysfs

  @dir "/sys/class/accel/accel0/device/"
  @groups ["NOC", "FREQ"]
  # NOC_timestamp ticks: the 19.2 MHz crystal (measured: 10 reports at a
  # 100 ms period span 19.2e6 ticks).
  @tick_hz 19_200_000
  @series [dma: "NOC_noc", riscv: "L2C_Riscv", shave: "L2C_Shave"]

  @impl true
  def defaults,
    do: [
      interval: 1_000,
      idle_interval: 2_000,
      enabled: true,
      driver_path: "/run/opengl-driver/lib"
    ]

  @impl true
  def init(opts) do
    port_mod = opts[:port_module] || Jantar.NpuPort
    exe = opts[:exe] || port_mod.exe()

    cond do
      not opts[:enabled] ->
        {:unavailable, :disabled}

      not Sysfs.exists?(opts[:root], @dir <> "npu_busy_time_us") ->
        {:unavailable, :no_npu}

      not File.exists?(exe) ->
        {:unavailable, :no_npu_port}

      true ->
        state = %{
          root: opts[:root],
          idle_interval: opts[:idle_interval],
          port_mod: port_mod,
          port_opts: [exe: exe, driver_path: opts[:driver_path]],
          port: nil,
          layout: nil,
          busy: nil,
          awake: false,
          prev: nil,
          clocks: %{dpu_mhz: nil, nce_mhz: nil}
        }

        {:ok, state, for({name, _} <- @series, do: {{:npu, name}, 5 * 60_000})}
    end
  end

  @impl true
  def sample(state, _now) do
    case Sysfs.number(state.root, @dir <> "npu_busy_time_us") do
      nil ->
        {:unavailable, :unreadable, shut(state)}

      busy ->
        working = state.busy != nil and busy > state.busy
        awake = Sysfs.read(state.root, @dir <> "power/runtime_status") == "active"
        state = %{state | busy: busy, awake: awake}

        case step(state, working and awake, working) do
          {:ok, readings, rates, state} -> {:ok, readings, current(state, rates), state}
          {:error, reason, state} -> {:unavailable, {:npu_port, reason}, shut(state)}
        end
    end
  end

  @impl true
  def next_interval(state, interval) do
    if state.layout || state.awake, do: interval, else: max(interval, state.idle_interval)
  end

  # Closed, and the NPU has started working: open the streamers. Rates
  # start with the next read.
  defp step(%{layout: nil} = state, true = _wake, _working) do
    with {:ok, state} <- ensure_port(state) do
      case state.port_mod.open(state.port, @groups) do
        {:ok, layout} -> {:ok, [], nil, %{state | layout: layout, prev: nil}}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp step(%{layout: nil} = state, _wake, _working), do: {:ok, [], nil, state}

  # Open, and still working: read and diff.
  defp step(state, _wake, true) do
    case state.port_mod.read(state.port, state.layout) do
      {:ok, groups} ->
        groups = Map.new(groups, fn {name, reports, values} -> {name, {reports, values}} end)
        state = %{state | clocks: clocks(state.clocks, groups["FREQ"])}

        case groups["NOC"] do
          {reports, values} when reports > 0 ->
            rates = rates(state.prev, values)
            readings = for {name, _} <- @series, do: {{:npu, name}, rates && rates[name]}
            {:ok, if(rates, do: readings, else: []), rates, %{state | prev: values}}

          _ ->
            {:ok, [], nil, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Open, and the work has stopped: close so the NPU can suspend, and leave
  # a gap in the series.
  defp step(state, _wake, false) do
    case state.port_mod.close(state.port) do
      :ok ->
        gaps = for {name, _} <- @series, do: {{:npu, name}, nil}
        {:ok, gaps, nil, %{state | layout: nil, prev: nil}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ensure_port(%{port: nil} = state) do
    {:ok, %{state | port: state.port_mod.start(state.port_opts)}}
  rescue
    e -> {:error, {:start, Exception.message(e)}, state}
  end

  defp ensure_port(state), do: {:ok, state}

  # After an error: stop the program (a fresh one starts next time).
  defp shut(%{port: nil} = state), do: %{state | layout: nil, prev: nil}

  defp shut(state) do
    state.port_mod.stop(state.port)
    %{state | port: nil, layout: nil, prev: nil}
  end

  # Per-second rates of the cumulative counters, timed by the NPU's own
  # report timestamps.
  defp rates(nil, _values), do: nil

  defp rates(prev, values) do
    dt = (values["NOC_timestamp"] - prev["NOC_timestamp"]) / @tick_hz

    if dt > 0 do
      for {name, metric} <- @series ++ [dma0: "NOC_DMA_00", dma1: "NOC_DMA_01"], into: %{} do
        delta = values[metric] - prev[metric]
        {name, if(delta >= 0, do: delta / dt)}
      end
    end
  end

  # FREQ reports say kHz in fields named _hz (950000 while sysfs said
  # 950 MHz). Keep the last non-zero clock.
  defp clocks(clocks, {reports, values}) when reports > 0 do
    mhz = fn key, metric ->
      v = values[metric]
      if is_number(v) and v > 0, do: round(v / 1000), else: clocks[key]
    end

    %{dpu_mhz: mhz.(:dpu_mhz, "Freq_dpu_hz"), nce_mhz: mhz.(:nce_mhz, "Freq_nce_hz")}
  end

  defp clocks(clocks, _), do: clocks

  defp current(state, rates) do
    rate = fn name -> rates && rates[name] end

    Map.merge(state.clocks, %{
      streaming: state.layout != nil,
      dma: rate.(:dma),
      dma0: rate.(:dma0),
      dma1: rate.(:dma1),
      riscv: rate.(:riscv),
      shave: rate.(:shave)
    })
  end
end
