import Config

config :avwe, :worlds,
  ember_reach: [
    quire: "ember-reach",
    # Late summer 813 AR, before dawn: the year Mira Vale begins her survey.
    start: {813, day: 220, hour: 4},
    terrain: [
      river: [
        name: "the Ember",
        # A warm river (lore): the town "sits where the silt used to steam at dusk".
        flow_m3_s: 10.0,
        water_c: 40.0,
        # Its source was forgotten, so it has no pin. The generator places it
        # upstream of the Dry Bend.
        source: [
          id: "river-source",
          name: "The Source",
          description:
            "A hollow ringed with pale stones, where the Ember once welled up warm. The stones are dry.",
          from: "the-dry-bend",
          bearing: 20..70,
          cells: 45..70
        ],
        through: ["the-dry-bend", {"ember-reach", beside: :east, cells: 6}, "willow-docks"],
        exit: :south
      ],
      # "Their lodge looks down on Ember Reach from a rise of pale grass."
      rises: [{"ashwarden-lodge", height_m: 14, radius_cells: 18}],
      clay: [{"ember-reach", radius_cells: 4}]
    ],
    climate: [wind: [from: "south-west", m_s: 2.0]],
    miracles: [
      [
        id: "the-source-fails",
        # Canon gives only the year (812 AR). The day and hour are ours.
        at: {812, day: 200, hour: 15},
        target: "river-source",
        component: :spring,
        set: %{flow_m3_s: 0.0},
        cause: :unknown,
        note: "The Ember's source stops, for reasons nobody knows yet."
      ]
    ]
  ]

import_config "#{config_env()}.exs"
