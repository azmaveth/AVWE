import Config

config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040

config :avwe, data_dir: "worlds"
