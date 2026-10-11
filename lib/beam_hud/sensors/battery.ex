defmodule BeamHud.Sensors.Battery do
  @moduledoc """
  Battery power and charge (hud's read_power and read_battery).

  Every tick (1 s; the EC updates current and voltage about once a second):
  status, current_now and voltage_now give watts, negative while discharging.
  Series `:power` (W, 30 min). Status is read with them because it sets the
  sign. Every `:detail_every` ms (10 s): capacity and the time to empty/full.

  Also sets `BeamHud.Mode`'s `:on_battery` from the status.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.{Core, Mode, Sysfs}

  @impl true
  def defaults, do: [interval: 1_000, detail_every: 10_000]

  @impl true
  def init(opts) do
    case Sysfs.wildcard(opts[:root], "/sys/class/power_supply/BAT*") do
      [dir | _] ->
        state = %{
          root: opts[:root],
          dir: dir <> "/",
          detail_every: opts[:detail_every],
          detail_at: nil,
          pct: nil,
          minutes: nil
        }

        {:ok, state, [power: 30 * 60_000]}

      [] ->
        {:unavailable, :no_battery}
    end
  end

  @impl true
  def sample(state, now) do
    status = read(state, "status") || ""
    current = num(state, "current_now")
    watts = :hud_core@rate.battery_watts(current || 0.0, num(state, "voltage_now") || 0.0, status)
    Mode.set(:on_battery, status == "Discharging")

    state =
      if state.detail_at == nil or now - state.detail_at >= state.detail_every do
        read_detail(state, status, current || 0.0, now)
      else
        state
      end

    current = %{status: status, watts: watts, pct: state.pct, minutes: state.minutes}
    {:ok, [power: watts], current, state}
  end

  defp read_detail(state, status, current, now) do
    pct = num(state, "capacity")
    charge_now = num(state, "charge_now")
    charge_full = num(state, "charge_full")

    minutes =
      if charge_now && charge_full do
        Core.option(:hud_core@rate.battery_minutes(status, current, charge_now, charge_full))
      end

    %{state | pct: pct && trunc(pct), minutes: minutes, detail_at: now}
  end

  defp read(state, file), do: Sysfs.read(state.root, state.dir <> file)
  defp num(state, file), do: Sysfs.number(state.root, state.dir <> file)
end
