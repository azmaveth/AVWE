# AVWE autopilot: specification

> Written by the orchestrator on 2026-10-05 from docs/DESIGN.md sections
> 6.3, 7.1, 7.2 and 13. Where this spec and DESIGN.md differ, this spec wins
> and DESIGN.md gets updated afterwards.

Autopilot is what drives a body when nobody else does. It is a controller
like any other (DESIGN 7.1): it only ever acts through intents, it has no
back door into world state, and it hands the body over the moment a human,
an Arbor agent or Claude takes it. It does not need to be clever, only
believable over long stretches of history mode, and perfectly repeatable.

## 1. Control is state, and it is journaled

Who controls a body must be part of the region's state, because the
simulation (the autopilot system) has to know it, and replay has to
reproduce it. Leases today live only in the runtime `Registry`.

- New component on bodies: `control: %{holder: atom() | nil, since: time}`.
  `holder` is the controller kind (`:human`, `:mcp`, `:arbor`), or `nil`
  when the body is on its own. Seeded bodies start with `holder: nil`.
- Two new instant verbs in `Avwe.Actions` (and `Avwe.Intent`'s docs and
  `verb` type): `:control` sets `holder` to the intent's `controller` and
  emits `:control_taken` (`entity: body, data: %{controller}`); `:release`
  clears it and emits `:control_released`. Both succeed unless the body
  does not exist (`:no_such_body`, as for every verb). Taking control of a
  body one already controls, or releasing one nobody holds, still succeeds
  (reason `:already`). Every intent still ends in exactly one result.
- `Avwe.Session` submits `:control` right after it claims the lease (the
  Registry lease stays as the runtime's exclusivity check; the component
  is the simulation's truth), and `:release` when it closes or its sink
  dies (`terminate/2`; ignore errors if the world is already gone). Both
  go through `RegionServer.submit`, so they are journaled and replayed
  like every other input.
- **Idle:** a session option `idle_after` in real milliseconds (default
  10 minutes; tests pass 100). When no `act` has arrived for that long,
  the session submits `:release` and marks itself yielded, so the body
  goes back to its routine while the player reads. The next `act`
  submits `:control` first and then the act, in that order (both land in
  the same inbox, so they apply in sequence at the next step). Idleness
  is real time and lives in the session, never in the pure core.
- `Avwe.bodies/1` gains `controller: holder | :autopilot` read from the
  snapshot's `control` component, next to the existing `taken` flag.
- The old DESIGN wording "a controller that stays idle past a timeout"
  is this idle rule; document the default in `Avwe.connect/2`.

## 2. The autopilot system

`Avwe.Systems.Autopilot`, run after `Discovery` and before `Smoke`
(`@default_systems` and `Avwe.Test.Ember.@systems`):

```
Daylight, Miracles, Weather, River, Fire, Heat, Movement, Waiting,
Discovery, Autopilot, Smoke
```

For every body that has an `:autopilot` component and whose `control.holder`
is `nil`, in sorted id order, the system decides whether to act and, if so,
calls `Region.submit/2` itself (it is a pure reducer) with an intent whose
`controller` is `:autopilot` and whose ref is `"auto-<body>-<step>"`. Those
intents are applied at the start of the next step like any other. They are
derived state: they are **not journaled** (they never pass through
`RegionServer.submit`), and replay regenerates them identically because the
system is a pure function of the region and the tick, drawing randomness
only from `Tick.rng/2`.

A body with a controller is left entirely alone: no intents, no cancelling
of its current action (a human's intent replaces whatever autopilot had
started, with the existing `:replaced` interruption, which the human sees as
"You give up on going to ..."). When control is released, autopilot resumes
at the next step.

## 3. The brain

The first brain is a utility pick over a few candidates. Keep it in a pure
module `Avwe.Autopilot` (the system is thin). Each candidate is a map
`%{utility: float, intent: {verb, opts}, why: atom}`. The best wins; ties by
the order below. Autopilot decides only when the body has no `:action`, or
when a candidate's utility is at least `0.8` (urgent) and higher than the
utility recorded for the running action in `autopilot.current`.

Candidates, in order:

1. **Routine entry due** (utility 0.6). A body's `:routine` component is a
   list of entries `%{at: seconds_of_day, do: {verb, opts}, note: string}`.
   An entry is due when the step crosses its time (`Tick.crossed?/3` with
   `Calendar.day()` and `at`) and it has not been done today
   (`autopilot.done: %{index => day_number}`); when several entries are
   due in one long step, take the last one. `{:rest}` in `do` means wait
   until dawn (`:wait` with `%{until: :dawn}`).
2. **Warmth** (0.8 when cold, else absent). Cold means `env.air_c` below
   12 °C and no burning source felt at the body's cell (`Fire.felt/2`
   nil). If the body is at home (`home` within 2 cells) with a hearth
   there that is not burning, has fuel, and is *invited*, kindle it. If a
   burning hearth the body can see (within `Perception.sight_cells` or
   200 m, as fires are seen) is nearer than 500 m, go to it (go to the
   place it stands at if that is a known place, else `walk` toward it is
   not available: use `go` only to known places; a hearth at an unknown
   place is ignored). Otherwise, if away from home, go home.
   **Invited** is the Hearth Compact rule from DESIGN 6.6 and 7.2, made
   physical: a hearth is invited when the ground of its cell is at least
   `@invited_c` (18 °C, a module attribute) by `Heat.cell_c/2`, that is,
   when the house still holds the river's warmth, so a small fire catches
   easily. Bodies whose `:norms` include `:invited_fire` only kindle
   invited hearths; bodies without that norm kindle any hearth with fuel.
   This is what makes "many chimneys went cold" after 812 emerge from the
   model rather than being scripted: the same Mira, the same wood, the
   same cold night, lights her hearth in 812 and does not in 813.
3. **Rest** (0.5). When it is dark (`env.light == 0.0`) and the body is at
   home: wait until dawn. When dark and away from home: go home (0.55).
4. **Idle** (0.1): wait 10 minutes.

Record the choice in `autopilot: %{current: utility, why: atom, since: time,
done: %{...}}` so a game master can see why a body did what it did, and
emit a `:decided` event (`entity: body, data: %{why, intent_ref}`) that
perception ignores (game-master only, like `:miracle`).

Jitter: routine times get a deterministic offset per body per day drawn
from `Tick.rng/2` in `[-5, +5]` minutes, so two bodies with the same
routine do not move in lockstep. Nothing else is random.

## 4. Worldgen and config

`config/config.exs`, under `ember_reach`, a new key:

```elixir
characters: [
  "mira-vale": [
    norms: [:invited_fire],
    routine: [
      [at: "04:30", do: {:go, target: "the-dry-bend"}, note: "walks the banks before dawn"],
      [at: "06:30", do: {:follow, params: %{direction: :upstream}}, note: "the survey"],
      [at: "11:00", do: {:go, target: "ember-reach"}],
      [at: "18:00", do: {:go, target: "ashwarden-lodge"}, note: "warms her hands at the lodge"],
      [at: "19:30", do: {:go, target: "ember-reach"}],
      [at: "22:00", do: {:rest}]
    ]
  ]
]
```

`Worldgen.add_characters/2`: every seeded body gets `autopilot: %{current:
nil, why: nil, since: nil, done: %{}}` and `control: %{holder: nil, since:
nil}`; a body named in `characters:` also gets `routine` (times parsed to
seconds of day; `at` must be `"HH:MM"`, validated with ArgumentError like
hearths) and `norms`. Bodies not named get no routine and no norms: they
rest at night and keep warm, nothing else. `Avwe.start_world/2` passes
`:characters` through and the resume warnings in `RegionServer.reconfigure`
cover it (ignored on resume, with the usual warning). `Avwe.Test.Ember`
passes it through too.

DESIGN 10.3 says routines will one day be compiled from Quire prose by an
LLM at import time into sidecars; this config key is the shape such a
sidecar would produce, and the compiler is out of scope here.

## 5. Perception

Nothing new for bodies: a spectator already sees "Mira Vale leaves, heading
toward The Dry Bend." and "Mira Vale lights the kiln-house hearth."
`:decided`, `:control_taken` and `:control_released` are game-master
events and produce no percepts. A human who connects to a body mid-journey
sees the journey in `look` ("You are on your way to ...") and gets the
`:replaced` result if they override it.

## 6. Tests

All end-to-end tests go through sessions or telnet; unit tests cover the
brain.

Unit (`test/avwe/autopilot_test.exs`, on `Ember.region/2`):
1. Routine: from 813/220 04:00 with nobody connected, Mira has left for
   the Dry Bend by 04:40 and arrived by 05:00; she is at the lodge between
   18:10 and 19:20 and at home resting by 22:10. Each routine entry fires
   once per day (`done`), and the day's `:decided` events name the entries.
2. Jitter is deterministic and bounded: two builds give the same departure
   minute; it is within 5 minutes of 04:30; a second body with the same
   routine (hand-built) departs at a different minute.
3. Invited fire: 812/199 at 20:00 with Mira at home and the air below 12 °C
   (if the evening air is not cold enough, use 812/199 03:00 instead; probe
   `Weather.air_c`), she kindles the kiln-house hearth within 10 minutes;
   813/220 03:00, same cold, she does not (the hearth cell is below
   `@invited_c`); without the `:invited_fire` norm she does. The 813 case
   must assert the hearth stays cold for the whole night.
4. Rest: a body away from home at dark goes home; at home it waits until
   dawn; the Lantern Hollow bodies (no routine) do nothing by day.
5. Control: with `control.holder` set, autopilot submits nothing for a full
   day; when released it decides within one step.
6. Property: extend `test/avwe/journeys_test.exs` (or a new property) so
   random controller intents interleaved with autopilot's still give exactly
   one result per intent, counting the `auto-*` refs too.
7. Determinism: same seed twice and one-at-a-time vs batched advances give
   the same hash over a day with autopilot; history mode (24 × 3600 s) still
   runs the routine (she visits each routine target that day).
8. Idle: not here (sessions); see e2e.

End to end (`test/e2e/autopilot_test.exs`, sessions and telnet):
9. A watcher in an otherwise empty Ember Reach at 813/220 04:00 sees
   "Mira Vale leaves, heading toward The Dry Bend." and "Mira Vale arrives
   at The Dry Bend." within the first hour; by 23:00 the spectator look
   says she is at Ember Reach.
10. Taking over: connect as Mira at 04:35 (telnet): `look` shows "You are on
    your way to The Dry Bend."; `go lodge` → "You give up on going to The
    Dry Bend." then the walk; stepping past 06:30 shows no routine action
    (she stays at the lodge); `quit` → within two steps autopilot has her
    on the 11:00 entry when it comes (or the warmth/rest candidates), and
    the watcher sees her leave.
11. Idle: a session with `idle_after: 100` that does not act: after 150 ms
    and a step, Mira is back on her routine (`Avwe.bodies` says
    `controller: :autopilot`); `Session.act` retakes control (`:human`) and
    autopilot stops.
12. Replay: `test/e2e/persistence_test.exs` gets a test where Mira is on her
    own for a day (1440 steps) with a snapshot in the middle: the journal
    has no `controller: :autopilot` submit records, `rebuild_from_start`
    equals live, and a restart mid-journey resumes the journey.
13. The canon check, over sessions: a watcher at 812/199 18:00 (warm river)
    sees "Mira Vale lights the kiln-house hearth." that evening; a watcher at
    813/220 18:00 never does.

## 7. Rules

Follow CLAUDE.md. The core stays pure: the autopilot system and brain never
read the wall clock, the Registry or `:rand` directly. Keep the design
doc's vocabulary. Prose for existing events must not change. Match the code
style. `mix format`, `mix compile --warnings-as-errors`, `mix credo
--strict`, `mix test` clean; the full suite twice.
