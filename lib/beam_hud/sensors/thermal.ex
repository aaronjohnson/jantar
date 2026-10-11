defmodule BeamHud.Sensors.Thermal do
  @moduledoc """
  CPU package temperature: the coretemp hwmon's "Package ..." input (hud's
  discover and read_slow). Series `:temp` (°C, 30 min).
  """
  @behaviour BeamHud.Sensor
  alias BeamHud.Sysfs

  @impl true
  def defaults, do: [interval: 500]

  @impl true
  def init(opts) do
    case find_package_temp(opts[:root]) do
      nil -> {:unavailable, :no_coretemp_package}
      path -> {:ok, %{root: opts[:root], path: path}, [temp: 30 * 60_000]}
    end
  end

  @impl true
  def sample(state, _now) do
    case Sysfs.number(state.root, state.path) do
      nil -> {:unavailable, :unreadable, state}
      milli_c -> {:ok, [temp: milli_c / 1000], %{temp_c: milli_c / 1000, path: state.path}, state}
    end
  end

  @doc "The first coretemp tempN_input whose label starts with \"Package\"."
  def find_package_temp(root) do
    Enum.find_value(Sysfs.wildcard(root, "/sys/class/hwmon/hwmon*"), fn dir ->
      if Sysfs.read(root, dir <> "/name") == "coretemp" do
        Enum.find_value(Sysfs.wildcard(root, dir <> "/temp*_label"), fn label ->
          if String.starts_with?(Sysfs.read(root, label) || "", "Package") do
            String.replace_suffix(label, "_label", "_input")
          end
        end)
      end
    end)
  end
end
