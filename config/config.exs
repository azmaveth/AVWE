import Config

# The Ember Reach is run from its definition, priv/worlds/ember-reach/definition.json
# (docs/engine-spec.md, E1): everything the world is, as data. It was made from
# the Quire folder and priv/worlds/ember-reach/source.exs by
# `mix avwe.definition.export ember-reach`; Quire is not read when it runs.
config :avwe, :worlds, ember_reach: [definition: "ember-reach"]

# The rules a world can run (docs/engine-spec.md, 4): packages of them, and
# the preset a definition that names no ruleset runs. `sim`, the kernel's own
# rule, is always known and always runs.
config :avwe,
  rule_packages: [Avwe.Rules.PlayPackage, Avwe.Rules.Earthlike],
  default_preset: "earthlike"

# The web client (AvweWeb), on Bandit. Where it listens and its secret are
# per environment. A page's socket is opened only from the origin the page
# came from (`:conn`: same scheme, host and port as the request), and
# AvweWeb.LoopbackHost keeps pages to loopback names.
config :avwe, AvweWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "127.0.0.1"],
  render_errors: [formats: [html: AvweWeb.ErrorHTML], layout: false],
  pubsub_server: AvweWeb.PubSub,
  live_view: [signing_salt: "m5Zk0cWq"],
  check_origin: :conn

config :phoenix, :json_library, Jason

# One JavaScript file and one stylesheet, bundled from assets/ into
# priv/static/assets/ (`mix assets.build`; the dev server rebuilds on change).
config :esbuild,
  version: "0.28.2",
  avwe: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outdir=../priv/static/assets --entry-names=[name]),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
