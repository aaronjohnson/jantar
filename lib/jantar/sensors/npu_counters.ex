defmodule Jantar.Sensors.NpuCounters do
  @moduledoc """
  What the NPU is doing while it works, from its Level Zero counters
  (`Jantar.NpuPort`): how much of the time its compute engine runs, and the
  data its network-on-chip moves.

  There is no counter for the matrix (DPU) array itself. The nearest is
  `FRC_Dynamic`, which counts NCE clock cycles while that clock runs: divided
  by the NCE clock it is the share of time the engine computes (measured:
  100% flat out, 46% for a matrix job 45% of the time, 6.5% for 5%). It
  covers the DPU and the SHAVE vector cores together. `L2C_Shave` tells the
  SHAVE cores apart: 0 under convolutions alone, non-zero once vector work
  (softmax, normalisation, exp, sin) runs there.

  Any Level Zero call wakes a suspended NPU, and an open streamer keeps it
  awake. So the streamer is opened only once the NPU is awake and its busy
  time (sysfs, which leaves it asleep) has moved, and closed as soon as busy
  time stops moving, so the NPU can suspend again. Nothing is read while it
  sleeps; the series have gaps there.

  Only one streamer per metric group can be open on the device: while
  another tool (a profiler, a second jantar) holds them, opening fails.
  That isn't the sensor failing: it shows `in_use_elsewhere`, logs once, and
  tries again at most every 30 s.

  Series, 5 min: `{:npu, :compute}` (0..1, the engine's clock-on share) and,
  per second, `{:npu, :dma}` (all NOC DMA traffic, probably bytes),
  `{:npu, :riscv}` and `{:npu, :shave}` (L2 cache traffic of the RISC-V
  control cores and the SHAVE vector cores). The DPU and NCE clocks are in
  the current values.

  Options: `:enabled` (false turns it off), `:driver_path` (where the Level
  Zero loader finds libze_intel_npu), `:exe` and `:port_module` (tests).
  """
  @behaviour Jantar.Sensor
  require Logger
  alias Jantar.Sysfs

  @dir "/sys/class/accel/accel0/device/"
  @groups ["NOC", "FRC", "FREQ"]
  # NOC_timestamp and FRC_timestamp ticks: the 19.2 MHz crystal (measured:
  # 10 reports at a 100 ms period span 19.2e6 ticks; FRC_Fixed counts the
  # same).
  @tick_hz 19_200_000
  @series [dma: "NOC_noc", riscv: "L2C_Riscv", shave: "L2C_Shave"]
  # After the streamers couldn't be opened, wait this long before trying again.
  @retry_open_ms 30_000

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
          now: 0,
          # {reason, retry at} while another tool holds the streamers.
          blocked: nil,
          clocks: %{dpu_mhz: nil, nce_mhz: nil}
        }

        {:ok, state, for(name <- series(), do: {{:npu, name}, 5 * 60_000})}
    end
  end

  @impl true
  def sample(state, now) do
    state = %{state | now: now}

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
  # start with the next read. If they're taken, wait and try again later.
  defp step(%{layout: nil, blocked: {_, retry}} = state, true, _working)
       when state.now < retry,
       do: {:ok, [], nil, state}

  defp step(%{layout: nil} = state, true = _wake, _working) do
    with {:ok, state} <- ensure_port(state) do
      case state.port_mod.open(state.port, @groups) do
        {:ok, layout} ->
          if state.blocked, do: Logger.info("npu_counters: streamers free again")
          {:ok, [], nil, %{state | layout: layout, prev: nil, blocked: nil}}

        {:error, "zetMetricStreamerOpen" <> _ = reason} ->
          if state.blocked == nil,
            do: Logger.info("npu_counters: #{reason}; another tool holds the NPU's metrics?")

          {:ok, [], nil, %{state | blocked: {reason, state.now + @retry_open_ms}}}

        {:error, reason} ->
          {:error, reason, state}
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
        prev = state.prev || %{}
        {noc, frc} = {fresh(groups["NOC"]), fresh(groups["FRC"])}
        rates = rates(prev["NOC"], noc)
        compute = compute(prev["FRC"], frc, state.clocks.nce_mhz)

        readings =
          if(rates, do: for({name, _} <- @series, do: {{:npu, name}, rates[name]}), else: []) ++
            if(compute, do: [{{:npu, :compute}, compute}], else: [])

        prev = for {g, v} <- [{"NOC", noc}, {"FRC", frc}], v, into: prev, do: {g, v}
        {:ok, readings, Map.put(rates || %{}, :compute, compute), %{state | prev: prev}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Open, and the work has stopped: close so the NPU can suspend, and leave
  # a gap in the series.
  defp step(state, _wake, false) do
    case state.port_mod.close(state.port) do
      :ok ->
        gaps = for name <- series(), do: {{:npu, name}, nil}
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

  defp series, do: [:compute | Keyword.keys(@series)]

  # A group's newest values, or nil when no report came.
  defp fresh({reports, values}) when reports > 0, do: values
  defp fresh(_), do: nil

  # Per-second rates of the cumulative counters, timed by the NPU's own
  # report timestamps.
  defp rates(prev, values) when prev == nil or values == nil, do: nil

  defp rates(prev, values) do
    dt = (values["NOC_timestamp"] - prev["NOC_timestamp"]) / @tick_hz

    if dt > 0 do
      for {name, metric} <- @series ++ [dma0: "NOC_DMA_00", dma1: "NOC_DMA_01"], into: %{} do
        delta = values[metric] - prev[metric]
        {name, if(delta >= 0, do: delta / dt)}
      end
    end
  end

  # The share of time the NCE clock ran: its cycles counted, over the cycles
  # it would have run at its clock all along.
  defp compute(prev, values, nce_mhz) when prev == nil or values == nil or nce_mhz == nil,
    do: nil

  defp compute(prev, values, nce_mhz) do
    dt = (values["FRC_timestamp"] - prev["FRC_timestamp"]) / @tick_hz
    cycles = values["FRC_Dynamic"] - prev["FRC_Dynamic"]
    if dt > 0 and cycles >= 0, do: min(1.0, cycles / dt / (nce_mhz * 1.0e6))
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
      in_use_elsewhere: state.blocked != nil,
      dma: rate.(:dma),
      dma0: rate.(:dma0),
      dma1: rate.(:dma1),
      riscv: rate.(:riscv),
      shave: rate.(:shave),
      compute: rate.(:compute)
    })
  end
end
