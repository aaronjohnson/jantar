defmodule BeamHud.Sensors.Fan do
  @moduledoc """
  Fan speed in rpm: the cros_ec hwmon's fan1_input (the Framework's embedded
  controller), else the first readable fan1_input (hud's discover). Series
  `:fan` (rpm, 30 min). The EC updates it about once a second, hence 1 s.
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.Sysfs

  @impl true
  def defaults, do: [interval: 1_000]

  @impl true
  def init(opts) do
    case find_fan(opts[:root]) do
      nil -> {:unavailable, :no_fan}
      path -> {:ok, %{root: opts[:root], path: path}, [fan: 30 * 60_000]}
    end
  end

  @impl true
  def sample(state, _now) do
    case Sysfs.number(state.root, state.path) do
      nil -> {:unavailable, :unreadable, state}
      rpm -> {:ok, [fan: trunc(rpm)], %{rpm: trunc(rpm), path: state.path}, state}
    end
  end

  @doc "cros_ec's fan1_input if present, else the first hwmon with one."
  def find_fan(root) do
    fans =
      for dir <- Sysfs.wildcard(root, "/sys/class/hwmon/hwmon*"),
          Sysfs.read(root, dir <> "/fan1_input") != nil,
          do: {Sysfs.read(root, dir <> "/name"), dir <> "/fan1_input"}

    case List.keyfind(fans, "cros_ec", 0) || List.first(fans) do
      {_name, path} -> path
      nil -> nil
    end
  end
end
