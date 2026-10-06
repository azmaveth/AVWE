import Config

config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040

# The MCP server for language models: http://127.0.0.1:4041/mcp (see .mcp.json).
config :avwe, :mcp, port: 4041, world: :ember_reach

config :avwe, data_dir: "worlds"

# The web client, on loopback. TLS and a name belong to whatever fronts it
# (see docs/m2-spec.md, 3.4); its secret comes from AVWE_SECRET_KEY_BASE
# (config/runtime.exs).
config :avwe, AvweWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4042],
  server: true
