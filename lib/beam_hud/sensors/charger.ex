defmodule BeamHud.Sensors.Charger do
  @moduledoc """
  The USB-C charger's offer in watts: voltage_now x current_max of an online
  ucsi-source-psy-* supply (hud's read_battery; like hud, the last online
  port wins). No series, just the current value, every 10 s.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.Sysfs

  @impl true
  def defaults, do: [interval: 10_000]

  @impl true
  def init(opts) do
    case Sysfs.wildcard(opts[:root], "/sys/class/power_supply/ucsi-source-psy-*") do
      [] -> {:unavailable, :no_usb_c_power}
      ports -> {:ok, %{root: opts[:root], ports: ports}, []}
    end
  end

  @impl true
  def sample(state, _now) do
    online = Enum.filter(state.ports, &(Sysfs.read(state.root, &1 <> "/online") == "1"))

    watts =
      case List.last(online) do
        nil ->
          0.0

        port ->
          :hud_core@rate.charger_watts(
            Sysfs.number(state.root, port <> "/voltage_now") || 0.0,
            Sysfs.number(state.root, port <> "/current_max") || 0.0
          )
      end

    {:ok, [], %{watts: watts, port: List.last(online)}, state}
  end
end
