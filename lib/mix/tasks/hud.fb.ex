defmodule Mix.Tasks.Hud.Fb do
  @shortdoc "Run the dashboard on a Linux console's framebuffer"
  @moduledoc """
  Runs the sensors and the display: draws on the framebuffer whenever the
  dashboard's VT is in the foreground.

      mix hud.fb                         rust backend, /dev/tty12 (Ctrl+Alt+F12), /dev/fb0
      mix hud.fb --backend cairo --tty /dev/tty12

  Needs write access to /dev/fb0 (group video) and to the tty (log in on
  it, or own it). Without them, draw into a stand-in file:

      mix hud.fb --fb /tmp/fake-fb --size 1440x960 --active-file /tmp/active
      echo tty12 > /tmp/active           # "switch" to the dashboard's VT

  Other options:

    * `--seconds N` - stop after N seconds (default: run until Ctrl-C)
    * `--crash-after N` - cairo only: make the C program segfault after N
      seconds, to watch the supervisor restart it while the VM carries on
  """
  use Mix.Task

  @switches [
    backend: :string,
    tty: :string,
    fb: :string,
    size: :string,
    active_file: :string,
    seconds: :integer,
    crash_after: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    backend = Mix.Tasks.Hud.Png.choice(opts[:backend] || "rust", ~w(rust cairo))
    Mix.Task.run("app.start")

    display =
      [
        backend: backend,
        tty: opts[:tty] || "/dev/tty12",
        fb: opts[:fb] || "/dev/fb0",
        allow_crash: opts[:crash_after] != nil
      ] ++
        if(opts[:size], do: [size: Mix.Tasks.Hud.Png.parse_size(opts[:size])], else: []) ++
        if(opts[:active_file], do: [active_file: opts[:active_file]], else: [])

    {:ok, sup} = BeamHud.Display.start_link(display)

    Mix.shell().info(
      "beam-hud: #{backend} backend, drawing while #{display[:tty]} is in the foreground"
    )

    if after_s = opts[:crash_after] do
      Process.sleep(after_s * 1000)
      crash_demo(sup)
    end

    if seconds = opts[:seconds] do
      Process.sleep(seconds * 1000)
      Mix.shell().info("stats: #{inspect(BeamHud.Display.Ticker.stats())}")
      Supervisor.stop(sup)
    else
      Process.sleep(:infinity)
    end
  end

  # Segfault the C program and show that only it was replaced.
  defp crash_demo(sup) do
    backend = BeamHud.Display.Backend
    before = {Process.whereis(backend), BeamHud.Render.Cairo.os_pid(backend)}

    Mix.shell().info(
      "crash demo: cairo_port (OS pid #{elem(before, 1)}) will now dereference NULL"
    )

    BeamHud.Render.Cairo.crash(backend)
    Process.sleep(1500)
    now = {Process.whereis(backend), BeamHud.Render.Cairo.os_pid(backend)}

    Mix.shell().info(
      "crash demo: backend #{inspect(elem(before, 0))} -> #{inspect(elem(now, 0))}, " <>
        "OS pid #{elem(before, 1)} -> #{elem(now, 1)}; VM up #{div(:erlang.statistics(:wall_clock) |> elem(0), 1000)} s, " <>
        "display supervisor #{inspect(sup)} alive: #{Process.alive?(sup)}"
    )
  end
end
