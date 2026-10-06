import Config

# Run the Ember Reach in real time (one world minute per second) and let
# people in over telnet: `telnet localhost 4040`.
config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040

# The MCP server for language models: http://127.0.0.1:4041/mcp (see .mcp.json).
config :avwe, :mcp, port: 4041, world: :ember_reach

# Worlds keep their logs and snapshots under worlds/<id>, relative to the project root.
config :avwe, data_dir: "worlds"
