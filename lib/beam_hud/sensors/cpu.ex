defmodule BeamHud.Sensors.Cpu do
  @moduledoc """
  CPU load from /proc/stat (overall and per core), and the mean clock from
  each core's cpufreq/scaling_cur_freq (hud's read_cpu and read_slow).

  Series: `:cpu` (load 0..1, 5 min) and `:clock` (GHz, 30 min). Load is a
  delta between two readings, so the first sample has none. Clocks are read at
  most every `:clock_every` ms: 16 sysfs reads aren't worth doing 4x a second.

  Cores are classed as in hud: P cores from /sys/devices/cpu_core/cpus; of the
  rest, the slowest (by cpuinfo_max_freq) are LP-E cores, the others E cores.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.Sysfs

  @impl true
  def defaults, do: [interval: 250, clock_every: 1_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    case Sysfs.read(root, "/proc/stat") do
      nil ->
        {:unavailable, :no_proc_stat}

      stat ->
        ids = :hud_core@parse.cpu_ids(stat)
        max_mhz = Enum.map(ids, &((cpufreq(root, &1, "cpuinfo_max_freq") || 0) / 1000))
        p_cores = :hud_core@parse.cpu_list(Sysfs.read(root, "/sys/devices/cpu_core/cpus") || "")

        state = %{
          root: root,
          ids: ids,
          max_mhz: max_mhz,
          kinds: kinds(ids, max_mhz, p_cores),
          clock_every: opts[:clock_every],
          prev: nil,
          clock_at: nil,
          freqs: [],
          clock: nil
        }

        {:ok, state, [cpu: 5 * 60_000, clock: 30 * 60_000]}
    end
  end

  @impl true
  def sample(state, now) do
    case Sysfs.read(state.root, "/proc/stat") do
      nil ->
        {:unavailable, :no_proc_stat, state}

      stat ->
        times = :hud_core@parse.cpu_times(stat)

        {load, cores} =
          case :hud_core@rate.cpu_loads(state.prev || [], times) do
            {:ok, [all | cores]} -> {all, cores}
            {:error, nil} -> {nil, []}
          end

        state = %{state | prev: times} |> maybe_read_clock(now)

        readings =
          if(load, do: [cpu: load], else: []) ++
            if state.clock_at == now, do: [clock: state.clock], else: []

        current = %{
          load: load,
          core_loads: cores,
          ids: state.ids,
          kinds: state.kinds,
          max_mhz: state.max_mhz,
          freqs_mhz: state.freqs,
          clock_ghz: state.clock
        }

        {:ok, readings, current, state}
    end
  end

  # Mean of every core's current clock, in GHz; an unreadable core counts as 0
  # MHz, as in hud.
  defp maybe_read_clock(state, now) do
    if state.clock_at == nil or now - state.clock_at >= state.clock_every do
      freqs = Enum.map(state.ids, &((cpufreq(state.root, &1, "scaling_cur_freq") || 0) / 1000))
      clock = if freqs == [], do: nil, else: Enum.sum(freqs) / length(freqs) / 1000
      %{state | freqs: freqs, clock: clock, clock_at: now}
    else
      state
    end
  end

  defp cpufreq(root, cpu, file) do
    Sysfs.number(root, "/sys/devices/system/cpu/cpu#{cpu}/cpufreq/#{file}")
  end

  @doc "Each core's tier: \"P\", \"E\", \"LP\", or \"\" when the machine has no hybrid info."
  def kinds(ids, max_mhz, p_cores) do
    rest = for {id, mhz} <- Enum.zip(ids, max_mhz), id not in p_cores, do: mhz
    {top, low} = if rest == [], do: {0, 0}, else: {Enum.max(rest), Enum.min(rest)}

    for {id, mhz} <- Enum.zip(ids, max_mhz) do
      cond do
        p_cores == [] -> ""
        id in p_cores -> "P"
        mhz == low and low < top -> "LP"
        true -> "E"
      end
    end
  end
end
