defmodule BeamHud.Display do
  @moduledoc """
  The dashboard on a Linux text console: a renderer backend plus the process
  that decides when to draw.

      BeamHud.Display (rest_for_one)
      ├── backend   BeamHud.Render.Rust or BeamHud.Render.Cairo
      └── BeamHud.Display.Ticker

  `rest_for_one`: if the backend dies (the cairo program crashed, say), the
  ticker after it restarts too and maps the framebuffer again from a clean
  state. The ticker failing leaves the backend alone.

  Options (also `config :beam_hud, :display, [...]`):

    * `:backend` - `:rust` (default) or `:cairo`
    * `:tty` - the console to draw on, default "/dev/tty12" (Ctrl+Alt+F12)
    * `:fb` - framebuffer device, default "/dev/fb0", or a plain file to
      draw into for testing (then give `:size`)
    * `:size` - `{width, height}` of a stand-in file (default: from sysfs)
    * `:kd_mode` - set KD_GRAPHICS/KD_TEXT on the tty (default true; off for
      stand-in files)
    * `:active_file` - where the kernel names the foreground VT, default
      "/sys/class/tty/tty0/active"
    * `:max_fps` (4) and `:battery_max_fps` (2) - frame rate caps
    * `:allow_crash` - cairo only: allow the crash demo
  """
  use Supervisor

  def start_link(opts \\ []) do
    opts = Keyword.merge(Application.get_env(:beam_hud, :display, []), opts)
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    backend = BeamHud.Render.module(Keyword.get(opts, :backend, :rust))

    children = [
      {backend, name: BeamHud.Display.Backend, allow_crash: opts[:allow_crash]},
      {BeamHud.Display.Ticker, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
