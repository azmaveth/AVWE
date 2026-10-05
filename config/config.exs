import Config

config :avwe, :worlds,
  ember_reach: [
    quire: "ember-reach",
    # Late summer 813 AR, before dawn: the year Mira Vale begins her survey.
    start: {813, day: 220, hour: 4}
  ]

import_config "#{config_env()}.exs"
