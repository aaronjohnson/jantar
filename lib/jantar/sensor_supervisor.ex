defmodule Jantar.SensorSupervisor do
  @moduledoc """
  Starts one `Jantar.Sensor` process per source, `one_for_one`: a sensor that
  crashes is restarted alone. (Sensors already turn missing sources and
  exceptions into "unavailable", so restarts should be rare.)

  `config :jantar, sensors: [...]` picks the sources (default: all), and
  `start_sensors: false` starts none (the test config).
  """
  use Supervisor

  @all [
    Jantar.Sensors.Cpu,
    Jantar.Sensors.Memory,
    Jantar.Sensors.Net,
    Jantar.Sensors.Thermal,
    Jantar.Sensors.Fan,
    Jantar.Sensors.Battery,
    Jantar.Sensors.Charger,
    Jantar.Sensors.Npu,
    Jantar.Sensors.Gpu,
    Jantar.Sensors.Wifi,
    Jantar.Sensors.Link,
    Jantar.Sensors.CiRunner
  ]

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every source module, in display order."
  def all, do: @all

  @impl true
  def init(_opts) do
    sensors =
      if Application.get_env(:jantar, :start_sensors, true) do
        Application.get_env(:jantar, :sensors, @all)
      else
        []
      end

    children = for module <- sensors, do: {Jantar.Sensor, module: module}
    Supervisor.init(children, strategy: :one_for_one)
  end
end
