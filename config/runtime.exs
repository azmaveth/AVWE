import Config

# Where Quire keeps its worlds. Defaults to a Quire checkout next to this repo.
config :avwe,
  quire_root: System.get_env("AVWE_QUIRE_ROOT", Path.expand("../quire/data/worlds"))

# The web client's secret, in production: at least 64 bytes, e.g. from
# `mix phx.gen.secret`.
if config_env() == :prod do
  config :avwe, AvweWeb.Endpoint,
    secret_key_base:
      System.get_env("AVWE_SECRET_KEY_BASE") ||
        raise("AVWE_SECRET_KEY_BASE is not set (make one with `mix phx.gen.secret`)")
end
