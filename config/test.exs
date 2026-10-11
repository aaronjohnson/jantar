import Config

# Tests start sensors themselves, against fixture trees.
config :beam_hud, start_sensors: false
config :logger, level: :warning

# Don't ask gsettings in tests.
config :beam_hud, theme: :dark
