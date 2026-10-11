defmodule BeamHud.Sensors.Memory do
  @moduledoc """
  Memory in use from /proc/meminfo: (MemTotal - MemAvailable) / MemTotal, as
  hud's read_mem. Series `:mem` (0..1, 5 min).
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Sysfs}

  @impl true
  def defaults, do: [interval: 1_000]

  @impl true
  def init(opts) do
    if Sysfs.exists?(opts[:root], "/proc/meminfo") do
      {:ok, %{root: opts[:root]}, [mem: 5 * 60_000]}
    else
      {:unavailable, :no_proc_meminfo}
    end
  end

  @impl true
  def sample(state, _now) do
    case Core.meminfo(Sysfs.read(state.root, "/proc/meminfo") || "") do
      nil -> {:unavailable, :no_mem_total, state}
      mem -> {:ok, [mem: mem.used], mem, state}
    end
  end
end
