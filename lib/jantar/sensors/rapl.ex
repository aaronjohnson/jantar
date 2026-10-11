defmodule Jantar.Sensors.Rapl do
  @moduledoc """
  Where the power goes inside the machine, from Intel RAPL's energy
  counters (/sys/class/powercap/intel-rapl:*): the whole platform (`psys`),
  the CPU package, and within it the cores, the graphics (`uncore`) and the
  memory (`dram`). Watts are energy differences over time; the counters wrap,
  which the Gleam `rate.energy_watts` handles.

  The kernel makes these root-only (the "Platypus" attack: fine-grained
  power can leak secrets), so this needs read access granted to jantar's
  group (the NixOS module's `powercap` option); otherwise it is unavailable.

  Series `{:rapl, domain}` for each domain found (W, 30 min).
  """
  @behaviour Jantar.Sensor
  alias Jantar.{Core, Sysfs}

  @impl true
  def defaults, do: [interval: 1_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    domains =
      for dir <- Sysfs.wildcard(root, "/sys/class/powercap/intel-rapl:*"),
          name = Sysfs.read(root, dir <> "/name"),
          name in ["psys", "package-0", "core", "uncore", "dram"],
          Sysfs.read(root, dir <> "/energy_uj") != nil,
          max = Sysfs.read(root, dir <> "/max_energy_range_uj"),
          do: {domain(name), dir <> "/energy_uj", String.to_integer(max)}

    case domains do
      [] ->
        {:unavailable, :no_readable_rapl}

      _ ->
        {:ok, %{root: root, domains: domains, prev: %{}},
         for({d, _, _} <- domains, do: {{:rapl, d}, 30 * 60_000})}
    end
  end

  @impl true
  def sample(state, now) do
    readings =
      for {d, path, max} <- state.domains,
          uj = Sysfs.read(state.root, path),
          uj != nil,
          do: {d, String.to_integer(uj), max}

    watts =
      for {d, uj, max} <- readings,
          {uj0, t0} <- [state.prev[d]],
          w = Core.ok_or_nil(:jantar_core@rate.energy_watts(uj0, uj, max, now - t0)),
          w != nil,
          into: %{},
          do: {d, w}

    prev = for {d, uj, _} <- readings, into: %{}, do: {d, {uj, now}}
    series = for {d, w} <- watts, do: {{:rapl, d}, w}
    {:ok, series, watts, %{state | prev: prev}}
  end

  defp domain("psys"), do: :platform
  defp domain("package-0"), do: :package
  defp domain("core"), do: :cores
  defp domain("uncore"), do: :graphics
  defp domain("dram"), do: :memory
end
