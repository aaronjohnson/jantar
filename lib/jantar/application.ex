defmodule Jantar.Application do
  @moduledoc """
  The supervision tree:

      Jantar.Supervisor (rest_for_one)
      ├── Jantar.History           owns the ETS tables with every series
      ├── Jantar.SensorSupervisor  (one_for_one) one process per sensor
      ├── Jantar.Theme             Solarized dark/light, following the desktop
      └── Jantar.Display           only with `config :jantar, display: [start: true, ...]`

  `rest_for_one`: if History restarts, its tables are gone, so the sensors
  after it restart too and declare their series again. A sensor crashing
  restarts alone, and its history survives in History's tables.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Jantar.Mode.init()

    children =
      [
        Jantar.History,
        Jantar.SensorSupervisor,
        Jantar.Theme
      ] ++ display()

    Supervisor.start_link(children, strategy: :rest_for_one, name: Jantar.Supervisor)
  end

  # The dashboard starts with the app only if configured; otherwise
  # `mix jantar.fb` starts it.
  defp display do
    opts = Application.get_env(:jantar, :display, [])
    if opts[:start], do: [{Jantar.Display, opts}], else: []
  end
end
