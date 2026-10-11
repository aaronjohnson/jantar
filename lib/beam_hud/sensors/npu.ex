defmodule BeamHud.Sensors.Npu do
  @moduledoc """
  Intel NPU utilisation from the accel driver's cumulative busy time (hud's
  read_npu). Reading these files leaves the NPU asleep.

  Series `:npu` (0..1, 5 min). Samples every 250 ms while the NPU is awake
  (power/runtime_status "active") and every 2 s while it is suspended.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Sysfs}

  @dir "/sys/class/accel/accel0/device/"

  @impl true
  def defaults, do: [interval: 250, idle_interval: 2_000]

  @impl true
  def init(opts) do
    root = opts[:root]

    if Sysfs.exists?(root, @dir <> "npu_busy_time_us") do
      state = %{
        root: root,
        idle_interval: opts[:idle_interval],
        max_mhz: trunc(Sysfs.number(root, @dir <> "npu_max_frequency_mhz") || 0),
        prev: nil,
        awake: false
      }

      {:ok, state, [npu: 5 * 60_000]}
    else
      {:unavailable, :no_npu}
    end
  end

  @impl true
  def sample(state, now) do
    case num(state, "npu_busy_time_us") do
      nil ->
        {:unavailable, :unreadable, state}

      busy ->
        load =
          case state.prev do
            {busy0, t0} -> Core.ok_or_nil(:hud_core@rate.busy_fraction(busy0, busy, now - t0))
            nil -> nil
          end

        awake = Sysfs.read(state.root, @dir <> "power/runtime_status") == "active"

        current = %{
          load: load,
          awake: awake,
          mhz: trunc(num(state, "npu_current_frequency_mhz") || 0),
          max_mhz: state.max_mhz,
          mem_bytes: num(state, "npu_memory_utilization")
        }

        readings = if load, do: [npu: load], else: []
        {:ok, readings, current, %{state | prev: {busy, now}, awake: awake}}
    end
  end

  @impl true
  def next_interval(state, interval) do
    if state.awake, do: interval, else: max(interval, state.idle_interval)
  end

  defp num(state, file), do: Sysfs.number(state.root, @dir <> file)
end
