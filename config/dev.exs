import Config

# Run the Ember Reach in real time (one world minute per second) and let
# people in over telnet: `telnet localhost 4040`.
config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040
