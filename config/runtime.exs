import Config

# Settings for a release, from the environment (the NixOS module sets these).
# In development, mix tasks take options instead.
if config_env() == :prod do
  env = fn name, default -> System.get_env(name, default) end

  if dir = System.get_env("JANTAR_FONT_DIR"), do: config(:jantar, font_dir: dir)

  # systemd's StateDirectory=: history is saved there on shutdown.
  if dir = System.get_env("STATE_DIRECTORY"), do: config(:jantar, state_dir: dir)

  # Theme: "dark" or "light" pins it; "file:/some/path" follows a file that
  # contains "dark" or "light" (checked every minute); unset asks gsettings.
  case env.("JANTAR_THEME", "") do
    "file:" <> path -> config :jantar, theme: nil, theme_command: ["cat", path]
    theme when theme in ["dark", "light"] -> config :jantar, theme: String.to_atom(theme)
    _ -> :ok
  end

  if env.("JANTAR_DISPLAY", "0") == "1" do
    config :jantar, :display,
      start: true,
      backend: if(env.("JANTAR_BACKEND", "cairo") == "rust", do: :rust, else: :cairo),
      tty: env.("JANTAR_TTY", "/dev/tty12"),
      fb: env.("JANTAR_FB", "/dev/fb0"),
      max_fps: String.to_integer(env.("JANTAR_MAX_FPS", "4")),
      battery_max_fps: String.to_integer(env.("JANTAR_BATTERY_MAX_FPS", "2"))

    # For testing a release without a framebuffer: a stand-in file of this
    # size, and a stand-in for /sys/class/tty/tty0/active.
    if size = System.get_env("JANTAR_FB_SIZE") do
      [w, h] = size |> String.split("x") |> Enum.map(&String.to_integer/1)
      config :jantar, :display, size: {w, h}
    end

    if file = System.get_env("JANTAR_ACTIVE_FILE"),
      do: config(:jantar, :display, active_file: file)
  end
end
