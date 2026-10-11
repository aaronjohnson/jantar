import Config

# Where the sensors look for /proc, /sys, /run and /etc. Tests point this at
# fixture trees.
config :jantar, root: "/"

# History: every series keeps a time window (set by its sensor) but never more
# than this many points, which bounds memory: 30 min at 250 ms.
config :jantar, max_points: 7200

# Adaptive sampling for every sensor (each can also set `adaptive: true`).
config :jantar, adaptive: false

# When the display is hidden and the machine is on battery, multiply sensor
# intervals by this. 1 = no change (the mechanism exists; the display that
# reports visibility comes in a later milestone).
config :jantar, hidden_on_battery_factor: 1

# The dashboard (see Jantar.Display for every option). `start: true` runs it
# with the app; otherwise `mix jantar.fb` does. The default console is tty12
# (Ctrl+Alt+F12).
#   config :jantar, :display, start: true, backend: :rust, tty: "/dev/tty12"

# Colours: follow the desktop (gsettings) unless pinned:
#   config :jantar, theme: :dark

# Per-sensor settings override each sensor's defaults, e.g.
#   config :jantar, Jantar.Sensors.Cpu, interval: 500, adaptive: true

import_config "#{config_env()}.exs"
