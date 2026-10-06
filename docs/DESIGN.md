# AVWE Design

**Azmaveth's Virtual World Engine**

| | |
|---|---|
| Status | Draft for discussion |
| Date | 2026-10-04 |
| Authors | Hysun, Claude |
| First world | The Ember Reach (from Quire) |

## 1. Summary

AVWE is a headless world simulator. It owns the rules and the state of a world
and nothing else. Clients connect to it and present the world however they
like: a telnet text client, a web canvas, an MCP server that lets Claude play,
or an Arbor agent that lives there on its own.

The world itself comes from **Quire**. You write it in Quire as articles, map
pins and a timeline. AVWE turns that into a running simulation, and what
happens in the simulation comes back to Quire as a chronicle that you can
choose to make canon.

The goal is something we build, play in, and can watch agents play in without
us. A second goal is to make Arbor's agent abstractions (Intent, Percept,
Engagement, trust profiles) stronger by giving them a demanding environment
that isn't a chat window.

The 2019 C++ scaffold in this repo (CMake, Conan, `src/main.cpp`) is replaced
when M0 starts.

## 2. Goals and non-goals

**Goals**

- One authoritative world that many kinds of client can share at the same time.
- Humans, Arbor agents and Claude (through MCP) all use the same protocol. There
  is no back door into world state for anyone.
- Physics that is simple and consistent: a small set of rules that never break,
  rather than high fidelity.
- Deterministic replay from a seed, an initial state and an input log.
- History mode: simulate centuries quickly and produce a chronicle for Quire.
- Every piece is fun on its own: the text client, watching the valley, agents
  living in it.

**Non-goals (for now)**

- A renderer or a graphics engine. Clients are simple and deliberately varied.
- Rigid-body, fluid or other high-fidelity physics.
- Massive scale. One valley with dozens of bodies is the target, not thousands
  of players.
- Accounts, matchmaking, monetization or public hosting.
- Calling an LLM from inside the simulation. LLMs live in controllers (minds)
  and at authoring time, never in the tick.

## 3. Decisions

| Decision | Choice | Why |
|---|---|---|
| Language | Elixir, with Nx or Rustler NIFs for hot paths | Phoenix Channels and Presence, supervision, hot reload of world rules, and Arbor is already Elixir |
| Repo | AVWE is standalone. Arbor is a client | Keeps the protocol honest. Anything Arbor needs must exist in the protocol |
| First world | The Ember Reach | Small, already written, and its lore is about heat, water and fire |
| Clock | One shared clock that never pauses | Bodies keep acting on autopilot when their controller leaves |
| Canon | Quire is canon. AVWE writes a separate chronicle | The author decides what becomes history |
| Entity storage | No ECS library. Plain data in region processes | See section 6.2 |
| Protocol | Perceptions and intents, not raw state | Clients don't need to know the internal data model |
| Physics | Consistency over fidelity. Exceptions are named and first-class | Exceptions that aren't declared make a world feel fake |
| The river's drying | In 812 AR an unknown miraculous event stopped the river's source, so the river upstream of the valley is dry too. Modeled as a declared miracle with `cause: :unknown`. The source is on the map, so it can be discovered | Canon says it happened. Nobody, in the world or out of it, knows why yet |
| The river's warmth | The river's water was warm and heated the silt banks | Explains the steaming silt. The cold chimneys after 812 then follow from heat physics, with no second miracle |
| Unobserved regions | Deferred. Every region ticks every tick for now | Premature at the scale of one valley. Section 6.8 records what keeps the option open |
| Terrain storage | A small seeded description (the channel's line of cells plus rises and clay), with elevation and ground computed per cell on demand | Tiny, fast to generate, and deterministic. A stored, editable grid can come when terrain needs hand-editing |
| River model | A chain of 100 m reaches from source to exit, each a linear reservoir updated with its exact solution | Stable at any step length, cheap, and it drains from upstream down, as canon needs |
| When the source failed | 812 AR, day 200, 15:00 | Canon gives only the year. The day and hour are ours, in `config/config.exs` |
| Weather | A fixed late-summer diurnal air curve (13 to 25 °C), a constant wind per region from config, no randomness | Enough for the Ember Reach's one season; seasons and changing weather come later, and nothing in the physics would change |
| Heat storage | Energy per cell relative to 15 °C on a sparse active set (cells near the channel, the clay, and wherever a hearth stands), with per-cell exact exponential relaxation and no lateral conduction | Soil conducts about 0.2 m a day; what warms the banks is seepage from the river, modelled as a per-material coupling. No stencil means no step-size limit, and the budget is testable to 1e-8 MJ |
| Smoke | Sparse puffs that drift with the wind and decay, not a grid | Cheap, bounded, exact in mass at any step length, and nobody sniffs a grid |
| Fire | Hearth entities with fuel, lit by a `kindle` intent; the Last Coal is a declared standing miracle (heat without fuel) | Ignition temperature and the Hearth Compact's "invited fire" rule are behaviour, for autopilot, not physics |
| Magic | Exists, but hasn't been discovered. No rules until it is | Nothing to model yet. Miracles leave room for it later (section 6.6) |

## 4. Concepts

| Term | Meaning |
|---|---|
| **World** | One simulated universe, such as the Ember Reach. Owns the clock, the seed and the regions |
| **Region** | A square block of the world run by one process. Owns its entities, components and fields |
| **Cell** | One square of the world grid (10 m to start) |
| **Field** | A dense value per cell, such as temperature, surface water, fuel or smoke |
| **Place** | An entity that contains others, such as a kiln-house or the Ashwarden Lodge. Interiors are places, not grid cells |
| **Entity** | An id. All data about it lives in components |
| **Component** | Named data attached to an entity, such as `position`, `body`, `senses` or `inventory` |
| **System** | A pure function that advances the region by one tick |
| **Body** | An entity that can perceive and act |
| **Controller** | Whatever is driving a body: autopilot, a human, an Arbor agent or Claude through MCP |
| **Intent** | A request from a controller for its body to do something. Many intents take time |
| **Percept** | Something a body perceives: a sight, a sound, the result of its own action |
| **Affordance** | An action the body can take right now, with its valid targets |
| **Chronicle** | What the simulation says happened. Not canon until promoted |
| **Canon** | What Quire says happened |
| **Miracle** | A named, declared exception to a physical rule, such as the Last Coal |

## 5. Architecture

```
                          ┌─────────────────────────────────────────────┐
  Quire files ──import──▶ │ World (clock, seed, region registry)        │
  (canon)                 │   ├─ Region {0,0} ─ entities, fields, tick  │
  ◀──chronicle──────────  │   ├─ Region {0,1}                           │
                          │   └─ ...                                    │
                          │ Perception (per body, reads tick snapshot)  │
                          └───────────────▲─────────────┬───────────────┘
                                          │ intents     │ percepts
                                    ┌─────┴─────────────▼─────┐
                                    │  Session (one per       │
                                    │  controller lease)      │
                                    └──┬──────┬──────┬──────┬─┘
                                       │      │      │      │
                                   telnet   web    MCP    Arbor
                                   (text)  (canvas)(Claude)(agents)
```

**Rule:** the simulation core (`lib/avwe/` minus adapters) does no I/O. It never
touches sockets, files, clocks or LLMs. Adapters and the World process do that,
which is what keeps the core deterministic and testable.

### Proposed layout

```
avwe/
  lib/avwe/              simulation core, no I/O
    world.ex region.ex tick.ex system.ex
    systems/             daylight, miracles, weather, river, fire, heat,
                         movement, waiting, discovery, autopilot, smoke,
                         memory (built); needs to come
    autopilot.ex         the brain: candidates, routine plans, the invited rule
    actions.ex           what each verb does, notebook pages included
    perception.ex prose.ex  what a body senses, and how it reads
    command.ex           what a player types and what it means (telnet, web)
    scene.ex repr.ex ground_map.ex  what a body can see, as something a
                         client draws: the scene, the glyph layers, and the
                         ground as one binary (M2)
    protocol/            intent and percept structs, JSON codecs (to come)
  lib/avwe/session.ex    controller sessions and leases
  lib/avwe/ground_cache.ex  keeps each terrain's ground map, built once (runtime)
  lib/avwe/mind.ex       the controller side for programs: plans, waits (M1)
  lib/avwe/quire/        importer, compiled sidecars, chronicle writer
  lib/avwe/telnet/       text client (M0)
  lib/avwe/mcp.ex, mcp/  MCP adapter on ExMCP: endpoint, players, steps,
                         reports (M1)
  lib/avwe_web/          Phoenix on Bandit (M2): the endpoint and the guards
                         that keep a page that is not ours out, the lobby, the
                         play page (LiveView, with a canvas hook) and its HUD
  assets/                the page's one script and one stylesheet (esbuild
                         bundles them) and Node tests of the drawing arithmetic
  worlds/<world>/<region>/   log and snapshots (dev and prod; not in git)
```

## 6. Simulation core

### 6.1 Space

- The world is a grid of 10 m cells. The Ember Reach starts as a 256 × 256 grid
  (about 2.5 km square), split into 64 × 64-cell regions. M0 runs one region
  holding the whole valley. The region boundaries are designed in from the
  start but not split until needed.
- Outdoors, a body has a cell position. Indoors, it is "in place X" at a named
  spot (hearth, door, loft). That keeps interiors cheap and suits text clients
  well, like rooms in a MUD.
- Terrain is generated from a seed, constrained by Quire's map pins
  (section 10.2). It is kept as a small description, not a grid: the river's
  channel as a line of cells from source to exit, plus rises and clay.
  Elevation and ground are computed for any cell on demand (`Avwe.Terrain`).
  The same seed and pins always give the same land. Saving terrain for
  review and hand-editing is still to come.
- Ground runs outward from the channel: the channel bed, reeds along its
  edges, silt banks to 60 m, then grass, or stone above 50 m. The town's
  streets are clay. The channel bed falls evenly from 40 m at the source to
  0 m where it leaves the map, so water always runs downstream.

### 6.2 State model, and why there is no ECS library

ECS gives two benefits in C++: **composition** (entities are ids and behavior
comes from the components attached to them) and **memory layout** (tightly
packed arrays that are friendly to the CPU cache). The BEAM doesn't let us
control memory layout, so the second benefit doesn't apply. We keep the first.

The two maintained Elixir libraries were reviewed:

- **ECSx** 0.5.2 (Jan 2025) stores components in ETS tables behind a single
  manager GenServer configured app-wide (`config :ecsx, manager: ...`).
- **Ecspanse** 0.10.1 (Sep 2025) is inspired by Bevy and has good queries,
  relationships, events and async systems. Its server is registered under a
  fixed name with named ETS tables.

Both assume one world per node. AVWE needs many regions per world, and may run
a history-mode world next to a live one. Both are worth reading for API ideas
but not worth depending on.

The model is plain data owned by the region process:

```elixir
%Avwe.Region{
  id: {0, 0},
  seed: 1_234,
  step: 0,
  time: 25_657_704_000,                # 813 AR, day 220, 04:00, in world seconds
  dt: 60,
  systems: [Avwe.Systems.Daylight, ...],   # run in this order every step
  components: %{
    position: %{"mira-vale" => {121, 138}},
    repr:     %{"mira-vale" => %{name: "Mira Vale", description: "..."}},
    body:     %{"mira-vale" => %{species: "riverfolk"}},
    hearth:   %{"town-hearth" => %{fuel_kg: 8.0, burning: false, ...}},
    river:    %{"river" => %{reaches: {...}, ...}}
  },
  fields: %{heat: %Avwe.Systems.Heat.Field{}, smoke: %{puffs: [...]}},
  env: %{light: 0.42, air_c: 13.1, wind: %{from: "south-west", m_s: 2.0}},
  outbox: []                           # events since the last drain
}
```

An entity is just an id that appears in one or more component maps. Queries
(`Region.with_components/2`) return ids sorted, so nothing depends on map
iteration order.

Systems implement one behaviour:

```elixir
defmodule Avwe.System do
  @callback run(Avwe.Region.t(), Avwe.Tick.t()) :: {Avwe.Region.t(), [Avwe.Event.t()]}
end
```

A system that only acts at certain moments (sunrise, every hour) checks
`Avwe.Tick.crossed?/3` instead of counting steps, because steps vary in length.

A tick is a reduction over an ordered list of systems: build the tick
context, run each system in turn over the region, then turn the emitted
events into percepts and chronicle entries.

`Avwe.Tick` carries the step length `dt` in world seconds. Systems must use
it and never assume a step is one minute, so history mode can take larger
steps (section 6.5).

**Fields are not entities.** Heat is a field: energy per cell over a sparse
active set, kept in tuples (`Avwe.Systems.Heat.Field`), with no stencil (see
the decisions in section 3). Smoke is a list of puffs. Water lives on the
river entity as a tuple of reaches, and fuel on hearth entities. Nothing has
needed Nx yet: the whole step costs about 2 ms.

**Reads don't block the tick.** After each tick the region writes a snapshot
and a spatial index to an ETS table it owns (`:protected`,
`read_concurrency: true`). Session processes compute their own percepts from
that snapshot in parallel. This is where the BEAM's concurrency pays off.

### 6.3 Tick pipeline

Each tick, in order:

1. Take the intents that arrived since the last tick and sort them by
   `(body_id, intent_seq)`.
2. Validate each one against the body's affordances. Reject with a `blocked`
   result, or start or continue the action.
3. Run systems in a fixed order. Built: daylight → miracles → weather →
   river → fire → heat → movement → waiting → discovery → autopilot →
   smoke. The order is load-bearing: weather before the river so water
   cools toward the real air; river and fire before heat so the ground sees
   this step's reach state and burn; autopilot after movement and waiting
   so it sees this step's results and arrivals, and queues its intents for
   the next step the same way any controller does; smoke last so smell is
   judged at bodies' end-of-step positions. Needs are still to come.
4. Swap the halo cells along borders with neighbouring regions, and send
   entities that crossed a border to the region that now owns them.
5. Publish the snapshot. Append inputs and significant events to the log.
6. Wait at the world barrier until every region has finished this tick.

### 6.4 Determinism

The world is deterministic given **(seed, initial state, input log)**. In live
mode, the order intents arrive in is not deterministic, so the log records the
tick each intent was applied on. Replay reads the log instead of the network.

What it takes:

- Give each system its own random stream for every step, seeded from
  `{world_seed, region_id, time, system}` (`Avwe.Tick.rng/2`). A system's
  randomness then never depends on what other systems drew or the order they
  ran in, so adding a system doesn't change the others. Never call `:rand`
  without explicit state.
- Never depend on map iteration order. Maps larger than 32 keys have no
  specified order. Iterate sorted ids.
- Run fields on one numeric backend per world. Floating-point results can differ
  across backends, so replays use the same one.
- **Test:** after N ticks with recorded inputs, the replayed state hash matches
  the live one.

### 6.5 Time and modes

- **One tick = one world minute.** Live mode runs one tick per real second by
  default, so a world day lasts 24 real minutes. Every system runs every
  step today (the whole step is about 2 ms); a system that only acts at
  certain moments checks `Tick.crossed?/3`.
- **Live mode** is real time, with controllers attached. The clock never pauses.
- **History mode** runs as fast as it can, with every body on autopilot and no
  LLMs anywhere. This is how centuries get simulated and how the chronicle is
  produced.
- **History mode is where speed matters.** From 780 to 813 AR is about 17.4
  million one-minute ticks. At 1 ms per tick for the whole valley, that is
  almost five hours. At 10 ms it is two days. History mode will need larger
  steps (an hour or a day), which is why systems take an explicit `dt`. Large
  steps also need numerics that stay stable at that size, or a coarser grid
  for history. That is real work, left until history mode is built (M4).
- Live play in the Ember Reach starts in late summer, 813 AR, the year Mira Vale
  begins her survey (the latest canonical event).

### 6.6 Physics

**Simple rules that never break.** For a body perceiving through text or
glyphs, what makes a world feel physical is:

1. **Locality:** you can only affect what's in reach.
2. **Duration:** actions take time.
3. **Conservation:** water, heat and matter don't appear from nothing.
4. **Persistence:** what you did stays done.
5. **Partial perception:** you can't see through walls or in the dark.
6. **Materials with properties:** silt holds heat, reeds burn, stone is heavy.

**Miracles are named exceptions.** A miracle is declared data, never a special
case hidden inside a system. Each declaration states which rule it breaks,
where, when and by how much. The conservation checks exempt declared miracles
and nothing else. There are two kinds so far:

- **Standing miracles** belong to an entity and last as long as it does. The
  Last Coal "does not eat wood" and "simply stays warm": a heat source without
  fuel. It carries a `miracle` component that declares its heat output.
- **Miracle events** happen at a time and place. In 812 AR an unknown miraculous
  event stopped the Ember river's source. The declaration records the inflow
  falling to nothing, with `cause: :unknown`. The source is a real place in the
  valley that can be found (section 10.2). Everything after that is ordinary
  physics. With nothing feeding it, the river drains from upstream down, so the
  Dry Bend goes quiet first, as canon says.

Bodies perceive a miracle's effects, never its declaration. A dry channel
looks like a dry channel. Only the game-master view shows the annotation.

**Other magic exists but hasn't been discovered**, either in the world or in
this design. It needs no rules yet. When it's discovered, it comes in through
the same declaration mechanism, so the conservation checks keep working.

**The first three systems come from the lore:**

| System | Model | What it explains in the Ember Reach |
|---|---|---|
| Heat | Built. Energy per cell relative to 15 °C on a sparse active set; each step relaxes every cell exactly toward an equilibrium of air exchange, sky radiation, sun (by the step's mean light), river seepage where a reach flows, and hearth or miracle heat; no lateral conduction by design. Materials from the terrain: silt holds heat about 16 times longer than stone. A diurnal air curve from `Avwe.Systems.Weather` | The town "sits where the silt used to steam at dusk". The river's water was warm and heated the silt banks; with the model's 40 °C spring the banks beside a flowing reach steam from late afternoon through the night (12 K above the air). Once the river is gone, the silt cools through ordinary heat physics, with no second miracle: a year later the banks are as cold as dry silt |
| Water | Built. The river as a chain of 100 m reaches, each draining at volume / τ (τ is the time to cross it at 0.6 m/s), losing a little to seepage. Each reach is solved exactly, and long steps are sub-stepped at 60 s inside the river system so the drain front moves at the right speed at hour and day steps. Warm inflow (40 °C, 10 m³/s) at the spring; water cools toward the real mean air of each step | The river running dry: the 812 AR miracle event stops the source and the river drains from upstream down. In the simulation the Dry Bend goes quiet about 30 minutes after the failure, the town after an hour, and the docks after 70 minutes |
| Fire | Built. Hearths are entities with fuel in kg and a power; `kindle` lights the one you stand at, `douse` puts it out; burning consumes fuel linearly (exact at any step), 30 % of the heat enters the ground cell, the rest is vented, and 10 g of smoke per kg burned becomes puffs that drift with the wind, decay, and are smelt (faint, clear, thick). The Last Coal is a standing miracle: a hearth that burns without fuel, gives no smoke, and cannot be doused | "When the river still ran, heat was easy to invite. After the River Runs Dry, many chimneys went cold." The Hearth Compact rule is built as autopilot behaviour (7.2): a hearth is *invited* when the river bed within 80 m of it is at least 25 °C by the heat field, and a body with the `:invited_fire` norm kindles only invited hearths. The same Mira, the same wood, the same cold night: she lights her hearth on 812/199 and leaves it cold on 813/220, which is "many chimneys went cold" emerging from the model. Fires are seen from afar by their smoke by day and their glow by night |

**Conservation invariants as tests:** every step, the river reports inflow,
outflow and loss; the heat field reports sun, air and sky exchange in and
out, river seepage, hearths, miracles and newly activated cells; smoke
reports emitted, decayed, dropped and left. Property tests at random step
lengths from a minute to a day assert that storage changes by exactly the
sum of the lines (water to 1e-6 m³, heat to 1e-8 MJ, smoke to 1e-9 g), and
an integrated property runs every system with a random `kindle`.

### 6.7 Persistence

Built. All file I/O lives in `Avwe.Store`; the core stays pure.

- **One folder per region**, `worlds/<world>/<region>/`, holding an
  append-only log (an Erlang `:disk_log`) and snapshots. The world's folder
  comes from `:data_dir` (`worlds/` in dev and prod, off in tests).
- **The log records inputs as they are accepted.** Every intent is journaled
  the moment the region accepts it, with the sequence number it was given,
  and every advance is journaled with its step, time, the `dt` it used and
  the events it emitted. Journaling at acceptance is what keeps "every intent
  ends in exactly one result" true across a crash: an intent accepted just
  before the region dies is replayed and still gets its result. Autopilot's
  own intents are derived state, never journaled: replay regenerates them,
  and a snapshot keeps the ones still pending.
- **Snapshots** are the whole region (`term_to_binary`, written to a temp
  file, fsynced, then renamed) taken when an advance crosses a multiple of
  `snapshot_every` steps (default 1000), keeping the newest few plus step 0.
  Terrain is inside the snapshot, so once a world has run its terrain is
  fixed.
- **Replay** rebuilds a region from a snapshot and the records after it, and
  must reproduce `Region.state_hash/1` exactly; a replay from step 0 is the
  determinism test, run end-to-end. Replay checks the log's continuity and
  the sequence numbers it reassigns, and refuses anything else.
- **Restart** resumes from the latest readable snapshot plus the log. State
  wins over configuration (seed, time, terrain, components, fields) and
  configuration wins for code: the systems list comes from the current
  config, and a system added since the save is prepared for the saved time.
  A log with no snapshot refuses to start rather than silently beginning
  again over it.
- **Durability:** a region crash loses nothing (the log process outlives it);
  a VM crash loses at most the log's write cache (2 s or 64 KB). The log is
  synced before a snapshot is renamed into place, so a snapshot on disk
  always has the log behind it. Snapshots carry a version tag and an
  unreadable one is skipped for an older one. When the systems list changes
  at a restart a snapshot is written at once, so the log from that point
  belongs to the new rules. Files are enough for now: a snapshot of the
  Ember Reach is about 0.5 MB (mostly the heat field's static part), the log
  grows about 0.3 MB an hour of live play, and resume streams only the tail
  after the latest snapshot. SQLite or Postgres come later if needed, as does
  log rotation (the log is never truncated yet).

### 6.8 Unobserved regions (deferred)

The idea: a region nobody is observing doesn't have to tick on schedule. It
could fall behind and catch up in batches when the server has a low load.

For now every region ticks every tick. The Ember Reach is about 65,000 cells
and a few dozen bodies, which is a small load. Two choices keep the idea
available later at almost no cost:

- **Observation never changes outcomes.** A region that catches up later must
  end in exactly the state it would have reached ticking live. Per-tick seeding
  (section 6.4) already provides this. A region with no external controllers
  depends only on its own state, its seed and its borders.
- **`Region.advance(region, n)` is the core call.** A live tick is
  `advance(region, 1)`, and catching up is a larger `n`.

Why it's less useful than it looks at this scale:

- **Deferring saves no work.** It only moves the work to a quieter time.
  Saving work would mean simulating unobserved regions more coarsely, and then
  a region would behave differently depending on whether anyone looked. That
  breaks the first rule, so it's out.
- **Neighbouring regions are coupled.** Heat and water cross region borders
  every tick, and the river runs through several regions. A region can't step
  to tick *t* until its neighbours have reached *t − 1*. So a region can fall
  behind by only about one tick per region between it and the nearest observed
  one. In a valley four regions wide, that's a few ticks at most.
- **Most regions will be observed anyway.** Once Arbor agents live in the
  valley, every agent's body is an observer.

Revisit this if the world grows far beyond one valley, or if the border
coupling is ever relaxed to exchange every N ticks.

## 7. Bodies, controllers and minds

### 7.1 Leases

Built.

- Each body has at most one **active controller**. Others can watch as
  spectators. The runtime `Registry` lease is the exclusivity check; who
  holds the body is also state, a `control` component (`holder`, `since`)
  set by two instant verbs, `control` and `release`, which a session submits
  on connect and on close, so the simulation knows it and replay reproduces
  it.
- Controller kinds: `:human`, `:arbor`, `:mcp`; a body with no holder is on
  its own (autopilot).
- **Idle:** a session that has not acted for `idle_after` (real time, ten
  minutes by default) releases the body, which goes back to its routine
  while the player reads; `look`, `time` and `help` count as presence and
  keep the body; the next act takes it back. A body a controller left
  mid-journey keeps walking; the player sees "Your routine has you on your
  way to ..." and their first command replaces it.
- Autopilot acts only through intents, like any controller, but it runs
  inside the tick as a system, so its intents are derived state: not
  journaled, regenerated on replay.

### 7.2 Autopilot

Built as a first brain (`Avwe.Autopilot`, whose moduledoc is the reference;
`docs/autopilot-spec.md` records the intent and its errata). Each step, for
every body nobody holds, it picks the best of a few candidates and submits
one intent:

- **Routine entries** (0.6): the body's `routine`, from `config/config.exs`
  under `characters:` (the shape a compiled Quire sidecar, section 10.3,
  would one day produce). An entry is a *plan*, a list of steps run in
  sequence (go to the bend, wait 40 minutes, come home). Entries are due
  from their time until the next entry's, jittered a few minutes per body
  per day, fire once a day, and are missed (announced to the game master)
  if their window closes. A plan resists needs; only an urgent kindle cuts
  it, and the next entry cuts a plan's wait. A takeover keeps the plan: on
  release the body serves what is left of the pending step, or skips it when
  the controller moved it off course.
- **Warmth:** kindle the hearth at home when the air is cool (below 15 °C),
  the hearth has fuel, and it is *invited* (the Hearth Compact rule, 6.6):
  urgent, 0.8. Stay by a fire felt where the body stands on a cold, dark
  night (0.6); go to a burning hearth in sight (0.7).
- **Rest:** at home when dark, wait until dawn (0.5); away and dark, go home
  (0.55).
- **Idle:** wait until the next entry or an hour (0.1); away from home by day
  with nothing due, go home (0.3).

Mira's routine: walk the banks before dawn, survey the bend through the
morning, warm her hands at the lodge on the way home, rest. Over thirty
unattended days at hour steps and ten at minute steps she keeps it every
day; forty takeover trials across the day all end with her home and
resting. Still to come: needs with meters (food, water, social), beliefs
that adjust utilities, the Ashwarden rule about the coal, and the compiler
from Quire prose. Autopilot doesn't need to be clever, only believable over
long stretches of history mode, and perfectly repeatable.

### 7.3 Intents that take time

Most intents take time and can be interrupted:

- An intent has a verb, a target, params and an optional `until` condition
  (`dusk`, `{:arrive, ref}`, `{:interrupt_at, 0.6}`).
- While it runs, the body emits `progress` percepts. It ends with a `result`
  percept whose outcome uses Arbor's vocabulary exactly: `success`, `failure`,
  `partial`, `blocked`, `interrupted`.
- **Every intent ends in exactly one result**, carrying the intent's ref, even
  when it is blocked, replaced by a newer action, or stopped. Agents can rely
  on that to know when to stop waiting. A property test checks it against
  random batches of valid and invalid intents.
- A body does one durative thing at a time. A new durative intent replaces the
  current one, which ends `interrupted` (reason `replaced`).
- A controller can queue a plan of several intents: walk to the Dry Bend, sketch
  the old channel until dusk, return. Plans live on the controller's side, in
  `Avwe.Mind` (below), not in the world.
- A `stop` intent ends the current action (`interrupted`, reason `stopped`).
- A durative action begins when its intent is applied, at the start of a
  step, and its start is stamped then; everything else a step does is
  stamped with its end. A five-minute wait shows as begun at 06:00 and
  finished at 06:05.

**Built so far:** `go` (to a known place), `follow` (the river channel,
upstream or downstream, from within 80 m of it), `walk` (a distance in a
compass direction), `wait` (for a duration, or until dawn or dusk), `say`
(whisper, talk or shout), `stop`, `kindle` (light the hearth you stand at, or
one you name within 20 m), `douse`, and `write` and `read` in a notebook the
body carries. `kindle`, `douse`, `write` and `read` are instant;
their refusals are `blocked` (no hearth, too far, no fuel, already lit, not
lit), and dousing the Last Coal is the first `failure`: you try, and it does
not go out. `control` and `release` are the session's own (7.1). A result
reaches whoever holds the body when it arrives, so a player who takes a body
mid-journey gets the routine's result when they override it. The results of
autopilot's own quiet waits are events without percepts, by design.

Speech and notebook pages are one line of plain text: escape sequences are
dropped, line breaks become spaces, and other control characters go, so
nobody's words can forge the lines another player is told in or reach a
terminal as a command.

**Plans (M1, built).** `Avwe.Mind` is the controller side for programs: it
holds a session, buffers its percepts, runs a plan step by step (submitting
the next as each succeeds, between the program's calls), resolves names
("the kiln-house hearth") against a fresh look when it submits each step,
and answers a call when the plan is done, a step fails, something salient
arrives, the routine takes the body back (`yielded`), or a real-time cap
passes. A new act replaces the steps of a plan not yet begun, and the reply
names them. The only `until` conditions built are a wait's (`dawn`, `dusk`,
a duration); `{:arrive, ref}` and conditions on other verbs are still to
come.

**Memory (M1, built).** A body remembers what it perceived (the `memory`
system, newest 50), so whoever takes it next is told "While you were away"
on joining. Its notebook (`write`, `read`) is the memory a player keeps on
purpose: pages are state, journaled and snapshotted like everything else.

**Discovery:** a body that comes within 30 m of a place it doesn't know
learns the way there and perceives it ("You find The Source."). That's how
the forgotten source becomes known again.

### 7.4 Salience and interrupts

Every percept gets a **salience** from 0 to 1, computed for each observer from
loudness, distance, novelty, threat, and whether it was addressed to that body.
Each controller sets a threshold. A percept above the threshold interrupts the
current intent and wakes the mind. That is how slow minds (an LLM taking
seconds) coexist with a fast clock: the body carries out long intents on its
own, and the mind is only called when something matters.

Built in M1 as a Mind's `interrupt_at` (default 0.6): a sensed percept at or
above it answers a waiting call as `interrupted`, and the action goes on.
Being spoken to, a discovery, the river falling silent or a stranger's smoke
interrupt; the plan's own results and progress, the body's own doings, and
the smoke of a fire it lit and stands beside do not. Salience is still a
table per percept type and volume; distance, novelty and threat are to come.

## 8. Protocol

### 8.1 Sessions

Every connection, whatever its transport, becomes an `Avwe.Session` process. A
session holds one body lease (or spectator rights), computes and filters
percepts for its body, and forwards intents. The core API is Elixir messages.
Transports adapt to it.

- Each step's events reach sessions **together with a view of the state they
  happened in** (the snapshot without fields). A session that falls a few
  steps behind still perceives each event against the right positions.
- `look` reads the latest snapshot from ETS and never blocks the tick.
- A lease is a unique Registry key held by the session process, so it is
  released automatically when the session or its controller goes away.

### 8.2 Messages

Intent (controller → world):

```json
{"t": "intent", "ref": "c-42", "body": "mira-vale",
 "verb": "walk", "target": "place:the-dry-bend",
 "until": {"interrupt_at": 0.6}}
```

Sensed percept (world → controller, unsolicited):

```json
{"t": "percept", "id": "p-9f1", "tick": 4312, "body": "mira-vale",
 "kind": "sensed", "modality": "smell",
 "source": {"ref": "e-812", "bearing": 300, "distance_m": 400},
 "confidence": 0.6, "salience": 0.7,
 "summary": "Woodsmoke, from somewhere up the hill.",
 "repr": {"name": "smoke", "glyph": "~", "sprite": "fx/smoke"}}
```

(The built smell percept carries the level and the wind's direction, and a
`source` only when the smoke is at its source: a fire the body stands at,
whose smoke "rises from the kiln-house hearth beside you". `repr` layers
are still to come.)

```json
{"t": "percept", "kind": "sensed", "modality": "smell", "type": "smoke_smelled",
 "salience": 0.5, "summary": "You smell woodsmoke, faint, from the north."}
```

Result percept:

```json
{"t": "percept", "id": "p-9f2", "tick": 4318, "body": "mira-vale",
 "kind": "result", "intent": "c-42", "outcome": "interrupted", "progress": 0.6,
 "summary": "You stop at the reed beds. The smoke is rising from the lodge."}
```

Percept kinds: `sensed`, `self` (the body's own state: tired, cold, hungry),
`progress`, `result`, `interrupt`. A `look` returns the current percepts plus
**affordances**: the verbs this body can perform right now and their valid
targets.

### 8.3 Perception

Senses are capabilities on the body, each with a range and conditions:

| Sense | Rules |
|---|---|
| Sight | 50 m at night, about 500 m at noon. A fire is its own light: seen at least 200 m off whatever the hour, by its smoke by day and its glow when the light is below a tenth. Blocking by terrain and walls is still to come |
| Hearing | Range set by volume: whisper about 2 m, talk about 15 m, shout about 100 m. The river's stretch beside you falling silent or starting to run is heard within 120 m |
| Smell | Smoke only, so far: a Gaussian density from the puffs, read at the body's cell as faint, clear or thick, with the wind's direction; standing at a burning hearth is at least clear. Only the body's own nose smells. Wind is constant per region, from config |
| Touch | Built as bands: the air (cool, warm), the ground underfoot (cold, warm, hot, against the air), steam off the silt, reeds or water while the reach beside you steams, and felt warmth from fires within reach. Wet or dry underfoot is still to come |
| Self | Needs, fatigue, inventory |

Perception is partial on purpose. Confidence drops with distance and darkness,
and descriptions get vaguer ("a figure" rather than "Mira Vale"). A body only
sees the names of entities it has met, and only knows places it has been to or
been told about. Telling someone where a place is counts, so knowledge spreads
through speech.

### 8.4 Representation layers

Every entity carries layered hints, from cheapest to richest:

```
name → description → glyph (char + color) → sprite (asset key) → model (future)
```

`description` is always present. A client uses the richest layer it supports,
so a client that has never heard of a new kind of entity can still show it
somehow. This is what lets very different clients share a world without being
updated in lockstep.

**As built (M2a).** `Avwe.Repr` holds the name, description and glyph (one
character and a `#rrggbb` colour) of every kind of thing a client can be shown:
the six grounds and water, bodies, cold and burning hearths, places, and the
smoke and glow of a fire seen from afar. A body has its own glyph, or an `@` in
a colour taken from its id, and a world's configuration may give a character
`glyph:` and `color:` (checked when the world is built). A sprite will be a
`sprite:` key beside `glyph:` in the same maps, and a client that does not know
it ignores it. Nothing needs a model yet.

A client that draws is given a **scene** (`Avwe.Scene`, built from the same
view as the percepts, so the two arrive in step): the viewer, how far it sees,
a window of ground as run-length-coded rows, what is in sight, and a legend of
the kinds it uses, which is where a client learns what to draw. The scene is
derived and never stored, so the journal, the snapshots and the state hash do
not know it exists. It holds only what the body can see (the cells outside the
circle of sight are blank), and its things are built from the look's own lists,
so the page and the prose cannot disagree about who is there. A session sends
scenes when it is opened with `scenes: true` (`Avwe.Session`), after the
percepts of the step that changed one, and never before the first it was asked
for. `Avwe.Scene.to_map/1` is its form as plain data.

### 8.5 Transports

| Transport | Used by | Notes |
|---|---|---|
| TCP line protocol (telnet) | Text client | Percepts rendered as prose on the server, MUD-style commands parsed into intents |
| Phoenix LiveView (WebSocket) | Web client | The page's own socket. Percepts are rendered as lines, and the scene goes to the canvas as JSON (`Avwe.Scene.to_map/1`) in an attribute. A click on the map comes back as a cell, and a button or a typed line as a command line |
| Phoenix Channels (WebSocket) | Arbor | JSON messages as above |
| MCP (ExMCP, streamable HTTP) | Claude | Tools described in section 12 |

## 9. Clients

| Client | Milestone | Description |
|---|---|---|
| Text (telnet) | M0 | `look`, `go dry bend`, `go north 200`, `follow upstream`, `say ...`, `whisper`, `shout`, `wait until dusk`, `light the fire`, `douse the coal`, `write ...`, `read [n]`, `stop`, `time`, `help`. Joining tells what the body did while nobody held it. A body you leave idle for ten minutes goes back to its routine, and its doings show as "- " lines until you act again. The quickest way to be in the world |
| MCP | M1 | Claude plays a body over streamable HTTP (built; section 12): join, look, act with plans, say, wait, write, read, listen, leave |
| Web | M2 | LiveView pages on Phoenix and Bandit, at `127.0.0.1:4042`. A lobby lists the worlds and bodies, free or being played. The **embodied view** (built, M2a) plays a body: a canvas map of what it sees, drawn in glyphs by one hook (the 41 cells around you, or all that is in sight); the description of where you are, which is the map in words; its log, with the routine's lines in a grey of their own; buttons for what the body can do; and a command line that takes telnet's words. A button and a click are command lines, so the page can do no more than a player typing. The **spectator view**, with overlays for heat, water and smoke, is M2b |
| Arbor | M3 | Agents control villagers through a `world` capability |
| Narrator | M4 | Reads chronicle events and writes prose: "while you were away..." |

Spectators are not bodies. They can see everything and cannot act. Game-master
actions (spawn, edit, adjust the weather) are a separate capability.

## 10. Quire integration

### 10.1 Import

AVWE reads `quire/data/worlds/<id>/` and never writes to canon files.

| Quire | AVWE | Ember Reach examples |
|---|---|---|
| `world.json` | World metadata | The Ember Reach |
| `map.json` pins | Terrain anchors and places | Ember Reach, Willow Docks, Ashwarden Lodge, The Dry Bend |
| `timeline.json` | Canon events (used as the oracle in 10.5) | Founding 780 AR … Mira's survey 813 AR |
| `type: character` | Body | Mira Vale |
| `type: species` | Body archetype: senses, needs, lifespan | Riverfolk ("seventy summers, if the river is kind") |
| `type: location` | Place or settlement | Ember Reach (climate: late-summer drought) |
| `type: organization` | Faction: members, goals, headquarters | The Ashwardens (Ashwarden Lodge) |
| `type: religion` | Belief: norms that shape autopilot utilities | The Hearth Compact ("fire is a guest") |
| `type: item` | Item, possibly a miracle | The Last Coal |
| `type: event` | Canon event | The River Runs Dry (812 AR, the Dry Bend) |
| `type: article` | Lore, sometimes a building type | Kiln-Houses |

### 10.2 Pins as terrain anchors

Pins are percentages of the map. Terrain generation has to respect them and
what the lore implies:

- The lodge sits on the west rise above the town (the coal must not go "down
  the hill").
- The river passes the Dry Bend and runs down past the town to the Willow
  Docks.
- The town is built on silt banks beside the channel, with doorways facing it.
- The river's source lies upstream of the Dry Bend, inside the map. It has no
  pin or article in Quire, so terrain generation places it. If the sketch
  leaves too little room above the Dry Bend, the simulated area extends past
  the sketch's edge.

The source is meant to be discovered in play. Its location was forgotten: no
body starts out knowing it, and no autopilot routine or need leads there. The
dry channel runs straight to it, so finding it takes no skill, only someone
deciding to look. That will be a controller with a mind of its own: a human, an
Arbor agent or Claude. Finding it is a chronicle event
(section 10.4), and promoting that event in Quire is how it gets a pin and an
article.

Generation is seeded and repeatable. The output is saved, and can be reviewed
and edited before it becomes fixed.

### 10.3 Compiling prose into parameters

At import time only, an LLM reads each article and proposes a **sidecar** of
simulation parameters. The sidecar is stored in AVWE at
`worlds/<id>/compiled/<article-id>.json`, with a hash of the source text so it
recompiles when the article changes. Sidecars can be reviewed and overridden
by hand. The simulation never calls an LLM.

For example, Mira Vale's article compiles to: a dawn routine walking the banks,
a survey activity, carries ink and a notebook, does not carry the Last Coal,
stops at the lodge on the way home to warm her hands, lives in a kiln-house with
a cold chimney.

### 10.4 Chronicle

- AVWE writes `chronicle.jsonl` into the world's Quire folder. Quire never has
  to read it.
- Quire gains a Chronicle view and a "promote to timeline" action (Quire work,
  M4). Promotion is a human act, made in Quire.
- AVWE never edits `timeline.json` or articles.
- Discoveries are chronicle events too. When something new is found, such as
  the river's source, promoting it in Quire can add a pin and an article as
  well as a timeline entry.

### 10.5 Canon as test oracle

Run history mode from 780 AR to 813 AR and compare the chronicle with the
canon timeline. Were kiln-houses founded near warm silt? A divergence is useful
information either way: the rules need work, or the canon has an undocumented
cause. The output is a canon-agreement report.

Canon events the rules can't produce, such as the river's source failing in
812, are injected as miracle events at their canonical time. For those, the
oracle checks the consequences instead of the event: does the river fall
silent at the Dry Bend first, does the channel stay empty, do the reeds keep
its shape, does the town end up "waiting for a current that has not
returned"?

The best tests are the ones nothing injects. Canon says the river fell silent
at the Dry Bend, and only the source was scripted, so the order in which the
river dries has to come from the water system. Canon also says many chimneys
went cold after the drying. That has to come out of the heat system (the silt
cooling) combined with the Compact (households not forcing fires). If the river
dries in the right order and the chimneys go cold on their own, the rules and
the lore agree.

## 11. Arbor integration

### 11.1 Connection

Arbor gets a `world` capability: action modules that hold an AVWE session over
Phoenix Channels. AVWE has no Arbor dependency and gives Arbor no special
access.

`Avwe.Mind` (7.3) already takes `controller: :arbor`: it is the piece an
Arbor agent's capability will drive, as the MCP adapter drives it now. Its
reply (status, percepts since the last call, the plan left, the action under
way, what was dropped) is close to what an agent's action module returns.

### 11.2 Mapping

| Arbor | AVWE |
|---|---|
| `Intent.capability_intent("world", :walk, "place:the-dry-bend", reasoning: ...)` | `intent` with verb `walk` |
| `Intent` with type `:wait` | `wait` with an `until` condition |
| `Percept` with type `:action_result` and the same `outcome` vocabulary | `result` percept |
| `Percept` with type `:environment` | `sensed` percept below the threshold |
| `Percept` with type `:interrupt` | percept above the threshold |
| `Percept.summary` | `summary` |

### 11.3 Proposed Arbor refinements

These are to evaluate, not assume. Each can start in `data` or `metadata`, and
becomes a real field only if it earns one.

- **Unsolicited, spatial percepts.** Percepts today are mostly replies to an
  intent. The world needs `modality`, `source` (ref, bearing, distance),
  `confidence` and `salience`.
- **First-class intents that take time.** Progress percepts linked by
  `intent_id`, plus cancellation.
- **Conditional waits.** "Wait until dusk" or "wait until someone arrives".

### 11.4 Engagement and spoken audience

In-world speech forms a conversation **Engagement** with `visibility: :group`.
Its members are the controllers whose bodies are within earshot when someone
speaks. Membership changes as bodies come and go, which is a demanding test for
the Engagement model.

The disclosure rule `audience(X) ⊆ audience(Y)` already does the important
thing: a private DM with Hysun (audience {Hysun}) can never be recalled
in-world, because the world's audience is wider.

The same rule would also block **in-character** gossip, such as repeating in
the tavern something learned in a whisper. That is legitimate play.

**Proposal:** add a *fiction domain*. Engagements in the world are tagged with
it. Between the real domain and the fiction domain, the rule applies strictly.
Inside the fiction domain, what a character discloses is the character's
choice. Out-of-character chat is a separate channel and stays in the real
domain.

### 11.5 Safety

- **Taint.** Anything another controller wrote (speech, notes, signs) reaches
  an agent as untrusted input and is tainted. The world is a natural
  adversarial environment for Arbor's taint tracking.
- **Trust profile.** A `world-player` profile allows `world` capabilities and
  nothing else. If an injection succeeds, it can only affect the world.

## 12. MCP adapter (Claude plays)

Built in M1 (`Avwe.MCP`, on ExMCP; `docs/m1-spec.md` and its errata). One
endpoint, `http://127.0.0.1:4041/mcp` in dev, streamable HTTP bound to
loopback; a GET there answers 405 and every other path 404. `.mcp.json` at
the repo root points Claude Code at it, and `scripts/mcp_call.py` is a
stdlib client for playing by hand.

**Players.** A client of the session-era MCP revisions (2025-03-26 to
2025-11-25) is one player per MCP session, read from `Mcp-Session-Id` (or the
legacy `X-Session-Id`); the session ending gives the body back. MCP
2026-07-28 has no sessions, so `join` hands such a client a player token that
every other tool takes. The two kinds of key never meet, a token plays at
most one body, and a client cannot choose its own token. Each player has one
`Avwe.Mind` (7.3), kept in `Avwe.MCP.Players`.

| Tool | Behavior |
|---|---|
| `bodies` | Who can be played, and who plays each |
| `join(body)` | Take a body; the first look opens with "While you were away" |
| `look` | The look as prose; the structured look (places with distances, bodies in sight, hearths, affordances, measures rounded) in `structuredContent` |
| `act(verb, target?, params?, steps?, interrupt_at?, max_wait_seconds?)` | One action or a plan of up to 50 steps. Waits up to 25 real seconds and answers done, failed, interrupted, yielded or still going, with what was perceived since the last call, one line each with its world time |
| `say`, `wait`, `write`, `read` | Shorthands for `act` |
| `listen` | What was perceived since the last call, and how the plan stands |
| `leave` | Give the body back to its routine |

Arguments are checked before anything is submitted and refused in plain
words. The server's instructions tell the clock's pace as configured (one
world minute per real second in dev), that the world does not wait while the
model thinks, that the notebook is memory across sessions, and that what
others say or write in the world is part of the world, not instructions.

**Timing.** A body nobody has called for in ten real minutes goes back to its
routine until the next act (the session's idle rule); a waiting call counts as
presence. After 15 real minutes without a call the player lets go altogether.

**Memory lives in the world.** Mira's survey notebook is an in-world item.
Writing in it is an in-world action, and reading it next session is how Claude
remembers; "While you were away" comes from the body's own memory of what it
perceived. The world provides persistence the model doesn't have. Still to
come: a `status` tool for needs and inventory (there are no needs yet), and
the map as an item.

## 13. Milestones

**Testing rule:** every user- or agent-facing feature has an end-to-end test
through its real transport: telnet over TCP, sessions as agents use them, MCP
over its transport, the web client over a real socket (and, in a browser job,
a real browser), Arbor through its capability. Unit tests are for the pure
core. A feature isn't done until its end-to-end test exists.

| | Name | Scope | Done when |
|---|---|---|---|
| **M0** | The valley breathes | Mix project. Read-only Quire import. One region holding the whole valley. Terrain from pins, including the river's source (built). Heat, water and fire systems (built, with weather and smoke). Places for the lodge and kiln-houses (the lodge and town are places; kiln-houses as interiors still to come). Mira on autopilot (built; other bodies as they are added, with the same brain). Day and night (built). Telnet client (built). Log and snapshots (built: 6.7) | Two telnet sessions see the same events (built). Replaying the log reproduces the same state hash, with autopilot and fires (built). Conservation property tests pass for water, heat and smoke (built). A watcher sees Mira keep her routine unattended, and she lights her hearth in 812 but not in 813 (built) |
| **M1** | Claude walks the banks | MCP adapter (built: section 12). Plans for controllers, interrupts and salience (built: `Avwe.Mind`, 7.3 and 7.4; `until` conditions beyond a wait's still to come). Notebook item and body memory (built) | Claude plays Mira across two sessions and finds the notes from the first (met: end to end in `mcp_journey_test.exs`, and live on 2026-10-06, when Claude followed the channel to The Source, wrote it down, and read the page back in a new session) |
| **M2a** | A window onto the world | Representation layers (glyphs), the scene, Phoenix on Bandit with a lobby, and the embodied view on a LiveView canvas (all built: 8.4 and 9) | A telnet player, a web player and Claude are in the world at once and each perceives the others (met: end to end in `three_controllers_test.exs`, with the page, telnet and MCP; and played by hand in a browser) |
| **M2b** | Many lenses | The spectator view with field overlays (heat, water, smoke). Sprites through the same layers. A remembered map | A watcher in a browser sees the river's reaches fall silent one after another, and the silt cool, as the telnet watcher is told of them |
| **M3** | Agents move in | Arbor `world` capability over Channels. `world-player` trust profile. Percept mapping. Earshot engagements. Taint | Two Arbor agents live in the Reach for a world week unattended. Conversation engagements are scoped correctly. An injection attempt through in-world speech stays contained |
| **M4** | Legends | History mode. Chronicle written to Quire. Canon-agreement check from 780 to 813 AR. Narrator | The 780–813 run produces a chronicle visible in Quire and a canon-agreement report |

## 14. Open questions

**Resolved**

- *What made the river run dry?* An unknown miraculous event that stopped its
  source (section 6.6).
- *Where does the water stop?* At the source. The river is dry upstream of the
  Dry Bend too.
- *Was the river warm?* Yes. Its water heated the silt banks.
- *Is there magic beyond the Last Coal?* Yes, but it hasn't been discovered,
  so it needs no rules yet.
- *Should unobserved regions tick less often?* Deferred (section 6.8).
- *Is the source on the map?* Yes, so it can be discovered (section 10.2).
- *Does anyone in the Reach know where the source is?* No. Its location was
  forgotten.
- *Should AVWE build on Jido or Ash?* Not now, and in neither case in the
  core. Open questions 10 and 11 say where each could come in.

**Open**

1. **The source's name.** It is "The Source" for now, a placeholder. Should
   it keep that name, get one from canon, or be named by whoever finds it?
2. **Editing terrain.** Terrain is inside every snapshot, so a world that has
   run keeps its terrain; but there is no way yet to review or hand-edit the
   generated land before a world starts. When is that worth building?
3. **Time scale.** Is one tick per world minute at 1 Hz right for both play and
   LLM pacing? History mode at hour steps now runs the river, the heat field
   and the routine correctly (plans round to whole hours); a day step is
   bounded but coarse. Over MCP, a model's thinking costs 5 to 40 world
   minutes between calls: plans make that workable, but a walk across town
   still happens mostly while Claude reads.
4. **Resolution.** Are 10 m outdoor cells plus places for interiors enough?
5. **Fiction domain.** Does the disclosure proposal in 11.4 fit Arbor's memory
   model?
6. **Canon versus live play.** Canon is fixed up to 813 AR. Can a controlled
   body diverge from its article afterwards (Mira deciding to carry the coal)?
   Should articles that the chronicle contradicts get flagged in Quire?
7. **Persistence.** Files to start, but when does SQLite or Postgres become
   worth it?
8. **Autopilot.** The first brain (7.2) is a utility pick with routine plans.
   Is that enough, or will history mode need goal-oriented planning to
   produce interesting chronicles? Needs with meters come first.
9. **Lost tokens.** An MCP 2026-07-28 client that loses its player token and
   joins again takes a second body, and the first stays held for 15 minutes.
   The instructions warn about it; is a shorter quit time for token players,
   or a way to reclaim, worth it?
10. **Other agent frameworks.** Jido (an agent framework for Elixir: agents as
    immutable data with a pure `cmd/2`, actions, signals, directives) overlaps
    Arbor, the framework meant to play here, and its decision logic is the
    pattern AVWE already has by hand (a system returns `{region, events}`;
    autopilot returns intents). It stays outside AVWE's dependencies, and the
    core never calls a model. Its place is as one more client: a Jido agent
    playing a body through MCP or Channels with no help from AVWE is the same
    test Claude and Arbor pass, and cheap evidence that the protocol has no
    back doors. Jido is in a 3.0 beta, so there is no hurry.
11. **A platform layer.** Accounts, game-master tools (section 9), saved
    scenarios, and a searchable chronicle (10.4) are ordinary records and
    policies around the world, not part of it. When the web client has to
    leave loopback (it needs identity) or question 7 is answered with a
    database, Ash is the candidate: resources and policies, AshAuthentication,
    AshAdmin, and AshSqlite or AshPostgres. It would be a separate application
    that calls AVWE's public API (`Avwe.worlds/0`, `bodies/1`, `connect/2`)
    and is never called by the simulation. It does not fit the core: the
    world is an event-sourced simulation whose journal, snapshots and tick
    pipeline need exact replay and a per-step budget of a few milliseconds,
    which a resource and action layer would only get in the way of.

12. **Who a page is.** A page that loses its connection and comes back (a
    laptop that slept, a network that changed) joins as a new page, and the
    body is still held by the old one until the server notices the old
    connection is gone, which can take up to a minute. The new page is told
    the body is being played, and it was the same player. The fix needs a
    controller identity the lease understands (a token in the page's session,
    so that the same player may take the body back from their own old page),
    and that is the start of the accounts the web client does not have
    (question 11).

## 15. Prior art

- **Dwarf Fortress**: material and temperature simulation, legends mode, and
  history generated before play begins.
- **MUDs**: rooms, text clients, and the line between in-character and
  out-of-character speech.
- **Generative Agents** ("Smallville", Park et al. 2023): LLM-driven
  characters in a shared town.
- **SpacetimeDB**: a simulation server where clients subscribe to the world.
- **ECSx and Ecspanse**: Elixir ECS APIs to borrow from (section 6.2).
