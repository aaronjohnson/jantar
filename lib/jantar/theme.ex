defmodule Jantar.Theme do
  @moduledoc """
  Solarized dark or light, following the desktop's colour scheme like hud
  (`gsettings get org.gnome.desktop.interface color-scheme`, checked every
  60 s; the bar flips it at sunrise and sunset). Dark if it can't be asked.

  The current theme is kept in `:persistent_term` (read every frame, written
  a couple of times a day). `config :jantar, theme: :dark | :light` pins it.
  """
  use GenServer

  @key {__MODULE__, :theme}
  @every_ms 60_000
  @command ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]

  @palettes %{
    dark: %{
      bg: "#002b36",
      surface: "#073642",
      muted: "#586e75",
      dim: "#657b83",
      fg: "#93a1a1"
    },
    light: %{
      bg: "#fdf6e3",
      surface: "#eee8d5",
      muted: "#93a1a1",
      dim: "#839496",
      fg: "#586e75"
    }
  }
  @accents %{
    yellow: "#b58900",
    orange: "#cb4b16",
    red: "#dc322f",
    violet: "#6c71c4",
    magenta: "#d33682",
    blue: "#268bd2",
    cyan: "#2aa198",
    green: "#859900"
  }

  @doc "The colours of a theme as 0xRRGGBB integers, keyed by role (:bg, :fg, :red, ...)."
  def palette(name) do
    Map.merge(@palettes[name], @accents)
    |> Map.new(fn {k, v} -> {k, Jantar.Render.DisplayList.hex(v)} end)
  end

  @doc "The current theme name, :dark or :light."
  def current, do: :persistent_term.get(@key, :dark)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    pinned = Keyword.get(opts, :theme, Application.get_env(:jantar, :theme))

    command =
      Keyword.get(opts, :command, Application.get_env(:jantar, :theme_command, @command))

    state = %{pinned: pinned, command: command}
    set(pinned || ask(command))
    unless pinned, do: Process.send_after(self(), :check, @every_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    set(ask(state.command))
    Process.send_after(self(), :check, @every_ms)
    {:noreply, state}
  end

  defp set(theme) do
    if current() != theme or :persistent_term.get(@key, nil) == nil do
      :persistent_term.put(@key, theme)
    end
  end

  @doc "Ask the desktop: :light if gsettings says so, else :dark."
  def ask(nil), do: :dark

  def ask([exe | args]) do
    with path when path != nil <- System.find_executable(exe),
         {out, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      if out =~ "light", do: :light, else: :dark
    else
      _ -> :dark
    end
  end
end
