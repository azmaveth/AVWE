import Config

config :logger, level: :warning

# Tests that persist pass their own data_dir; nothing is written otherwise.
config :avwe, data_dir: nil
