defmodule BeamHud.SensorSupervisor do
  @moduledoc """
  Starts one `BeamHud.Sensor` process per source, `one_for_one`: a sensor that
  crashes is restarted alone. (Sensors already turn missing sources and
  exceptions into "unavailable", so restarts should be rare.)

  `config :beam_hud, sensors: [...]` picks the sources (default: all), and
  `start_sensors: false` starts none (the test config).
  """
  use Supervisor

  @all [
    BeamHud.Sensors.Cpu,
    BeamHud.Sensors.Memory,
    BeamHud.Sensors.Net,
    BeamHud.Sensors.Thermal,
    BeamHud.Sensors.Fan,
    BeamHud.Sensors.Battery,
    BeamHud.Sensors.Charger,
    BeamHud.Sensors.Npu,
    BeamHud.Sensors.Gpu,
    BeamHud.Sensors.Wifi,
    BeamHud.Sensors.CiRunner
  ]

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every source module, in display order."
  def all, do: @all

  @impl true
  def init(_opts) do
    sensors =
      if Application.get_env(:beam_hud, :start_sensors, true) do
        Application.get_env(:beam_hud, :sensors, @all)
      else
        []
      end

    children = for module <- sensors, do: {BeamHud.Sensor, module: module}
    Supervisor.init(children, strategy: :one_for_one)
  end
end
