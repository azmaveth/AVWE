import Config

# Run the Ember Reach in real time (one world minute per second) and let
# people in over telnet: `telnet localhost 4040`.
config :avwe, autostart: [ember_reach: [clock: {:live, 1_000}]]
config :avwe, :telnet, port: 4040

# The MCP server for language models: http://127.0.0.1:4041/mcp (see .mcp.json).
config :avwe, :mcp, port: 4041, world: :ember_reach

# Worlds keep their logs and snapshots under worlds/<id>, relative to the project root.
config :avwe, data_dir: "worlds"

# The web client: http://127.0.0.1:4042. Loopback only; there are no accounts,
# so anyone who can reach the port can take a free body.
config :avwe, AvweWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4042],
  server: true,
  # Not a secret: this is the development key.
  secret_key_base: "dev-only-key-for-the-avwe-web-client-not-a-secret-0123456789abcdef0123456789",
  watchers: [esbuild: {Esbuild, :install_and_run, [:avwe, ~w(--sourcemap=inline --watch)]}]
