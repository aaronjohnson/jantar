defmodule Jantar.Application do
  @moduledoc """
  The supervision tree:

      Jantar.Supervisor (rest_for_one)
      ├── Jantar.History           owns the ETS tables with every series
      ├── Jantar.SensorSupervisor  (one_for_one) one process per sensor
      ├── Jantar.Theme             Solarized dark/light, following the desktop
      ├── Jantar.Display           only with `config :jantar, display: [start: true, ...]`
      └── Jantar.NpuExperiments       only with the npu-experiment command configured


  `rest_for_one`: if History restarts, its tables are gone, so the sensors
  after it restart too and declare their series again. A sensor crashing
  restarts alone, and its history survives in History's tables. The
  experiment runner is last, so its crashing restarts nothing else.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Jantar.Mode.init()

    children =
      [
        Jantar.History,
        Jantar.SensorSupervisor
      ] ++
        wifi_events() ++
        [Jantar.Theme] ++ display() ++ npu_experiments()

    Supervisor.start_link(children, strategy: :rest_for_one, name: Jantar.Supervisor)
  end

  # Wi-Fi events run with the sensors (not in tests, which start their own).
  defp wifi_events do
    if Application.get_env(:jantar, :start_sensors, true), do: [Jantar.WifiEvents], else: []
  end

  # The NPU experiment runner, if the command is there (the NixOS module sets it).
  defp npu_experiments do
    opts = Application.get_env(:jantar, Jantar.NpuExperiments, [])

    if opts[:exe] && File.exists?(opts[:exe]),
      do: [
        {Jantar.NpuExperiments,
         Keyword.put_new(opts, :state_dir, Application.get_env(:jantar, :state_dir))}
      ],
      else: []
  end

  # The dashboard starts with the app only if configured; otherwise
  # `mix jantar.fb` starts it.
  defp display do
    opts = Application.get_env(:jantar, :display, [])
    if opts[:start], do: [{Jantar.Display, opts}], else: []
  end
end
