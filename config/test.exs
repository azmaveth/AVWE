import Config

config :logger, level: :warning

# Tests that persist pass their own data_dir; nothing is written otherwise.
config :avwe, data_dir: nil

# The web client listens on a port of the system's choosing (see
# AvweWeb.Endpoint.server_info/1), so tests can reach it over a socket, and the
# lobby is refreshed by the tests, not by a timer.
config :avwe, AvweWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  secret_key_base: "test-only-key-for-the-avwe-web-client-not-a-secret-0123456789abcdef012345678"

config :avwe, lobby_refresh_ms: nil
