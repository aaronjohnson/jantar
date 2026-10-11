import Config

# Where the sensors look for /proc, /sys, /run and /etc. Tests point this at
# fixture trees.
config :beam_hud, root: "/"

# History: every series keeps a time window (set by its sensor) but never more
# than this many points, which bounds memory: 30 min at 250 ms.
config :beam_hud, max_points: 7200

# Adaptive sampling for every sensor (each can also set `adaptive: true`).
config :beam_hud, adaptive: false

# When the display is hidden and the machine is on battery, multiply sensor
# intervals by this. 1 = no change (the mechanism exists; the display that
# reports visibility comes in a later milestone).
config :beam_hud, hidden_on_battery_factor: 1

# Per-sensor settings override each sensor's defaults, e.g.
#   config :beam_hud, BeamHud.Sensors.Cpu, interval: 500, adaptive: true

import_config "#{config_env()}.exs"
