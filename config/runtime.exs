import Config

# Settings for a release, from the environment (the NixOS module sets these).
# In development, mix tasks take options instead.
if config_env() == :prod do
  env = fn name, default -> System.get_env(name, default) end

  if dir = System.get_env("BEAM_HUD_FONT_DIR"), do: config(:beam_hud, font_dir: dir)

  # Theme: "dark" or "light" pins it; "file:/some/path" follows a file that
  # contains "dark" or "light" (checked every minute); unset asks gsettings.
  case env.("BEAM_HUD_THEME", "") do
    "file:" <> path -> config :beam_hud, theme: nil, theme_command: ["cat", path]
    theme when theme in ["dark", "light"] -> config :beam_hud, theme: String.to_atom(theme)
    _ -> :ok
  end

  if env.("BEAM_HUD_DISPLAY", "0") == "1" do
    config :beam_hud, :display,
      start: true,
      backend: if(env.("BEAM_HUD_BACKEND", "cairo") == "rust", do: :rust, else: :cairo),
      tty: env.("BEAM_HUD_TTY", "/dev/tty12"),
      fb: env.("BEAM_HUD_FB", "/dev/fb0"),
      max_fps: String.to_integer(env.("BEAM_HUD_MAX_FPS", "4")),
      battery_max_fps: String.to_integer(env.("BEAM_HUD_BATTERY_MAX_FPS", "2"))

    # For testing a release without a framebuffer: a stand-in file of this
    # size, and a stand-in for /sys/class/tty/tty0/active.
    if size = System.get_env("BEAM_HUD_FB_SIZE") do
      [w, h] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
      config :beam_hud, :display, size: {w, h}
    end

    if file = System.get_env("BEAM_HUD_ACTIVE_FILE"),
      do: config(:beam_hud, :display, active_file: file)
  end
end
