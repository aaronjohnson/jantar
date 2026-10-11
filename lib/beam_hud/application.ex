defmodule BeamHud.Application do
  @moduledoc """
  The supervision tree:

      BeamHud.Supervisor (rest_for_one)
      ├── BeamHud.History           owns the ETS tables with every series
      ├── BeamHud.SensorSupervisor  (one_for_one) one process per sensor
      ├── BeamHud.Theme             Solarized dark/light, following the desktop
      └── BeamHud.Display           only with `config :beam_hud, display: [start: true, ...]`

  `rest_for_one`: if History restarts, its tables are gone, so the sensors
  after it restart too and declare their series again. A sensor crashing
  restarts alone, and its history survives in History's tables.
  """
  use Application

  @impl true
  def start(_type, _args) do
    BeamHud.Mode.init()

    children =
      [
        BeamHud.History,
        BeamHud.SensorSupervisor,
        BeamHud.Theme
      ] ++ display()

    Supervisor.start_link(children, strategy: :rest_for_one, name: BeamHud.Supervisor)
  end

  # The dashboard starts with the app only if configured; otherwise
  # `mix hud.fb` starts it.
  defp display do
    opts = Application.get_env(:beam_hud, :display, [])
    if opts[:start], do: [{BeamHud.Display, opts}], else: []
  end
end
