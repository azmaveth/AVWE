import Config

# Where Quire keeps its worlds. Defaults to a Quire checkout next to this repo.
config :avwe,
  quire_root: System.get_env("AVWE_QUIRE_ROOT", Path.expand("../quire/data/worlds"))
