import Config

config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040

# The MCP server for language models: http://127.0.0.1:4041/ (see .mcp.json).
config :avwe, :mcp, port: 4041, world: :ember_reach

config :avwe, data_dir: "worlds"
