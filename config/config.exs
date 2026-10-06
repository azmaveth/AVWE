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
    hearths: [
      [
        id: "town-hearth",
        at: "ember-reach",
        name: "the kiln-house hearth",
        fuel_kg: 8.0,
        power_w: 5_000.0
      ],
      [
        id: "lodge-hearth",
        at: "ashwarden-lodge",
        name: "the lodge hearth",
        fuel_kg: 12.0,
        power_w: 5_000.0
      ]
    ],
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
      ],
      # "It does not smoke. It does not eat wood. It simply stays warm."
      [
        id: "the-last-coal",
        kind: :standing,
        at: "ashwarden-lodge",
        heat_w: 800.0,
        breaks: [:fuel, :dousing],
        cause: :unknown,
        note: "Heat without fuel, declared: the Last Coal does not eat wood."
      ]
    ],
    # What the bodies do on their own (Avwe.Autopilot). "She walks the banks
    # before dawn ... she stops at the lodge on the way home and warms her
    # hands"; her kiln-house keeps the Hearth Compact. Each entry is a plan,
    # run step by step. None leads to the source: that is for someone to
    # find (docs/DESIGN.md, 10.2).
    characters: [
      "mira-vale": [
        norms: [:invited_fire],
        routine: [
          [
            at: "04:30",
            do: [
              {:go, target: "the-dry-bend"},
              {:wait, params: %{for: 40 * 60}},
              {:go, target: "ember-reach"}
            ],
            note: "walks the banks before dawn"
          ],
          [
            at: "08:00",
            do: [
              {:go, target: "the-dry-bend"},
              {:wait, params: %{for: 3 * 3600}},
              {:go, target: "ember-reach"}
            ],
            note: "the survey"
          ],
          [
            at: "18:00",
            do: [
              {:go, target: "ashwarden-lodge"},
              {:wait, params: %{for: 90 * 60}},
              {:go, target: "ember-reach"}
            ],
            note: "warms her hands at the lodge on the way home"
          ],
          # Home first, wherever the day (or a player) left her, then rest.
          [at: "22:00", do: [{:go, target: "ember-reach"}, {:rest}]]
        ]
      ]
    ]
  ]

import_config "#{config_env()}.exs"
