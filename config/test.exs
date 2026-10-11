import Config

# Tests start sensors themselves, against fixture trees.
config :jantar, start_sensors: false
config :logger, level: :warning

# Don't ask gsettings in tests.
config :jantar, theme: :dark
