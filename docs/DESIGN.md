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
    systems/             heat, water, fire, movement, needs, autopilot
    fields/              dense grid helpers, Nx later
    perception/          senses, salience, representation layers
    protocol/            intent and percept structs, JSON codecs
  lib/avwe/session.ex    controller sessions and leases
  lib/avwe/quire/        importer, compiled sidecars, chronicle writer
  lib/avwe/telnet/       text client (M0)
  lib/avwe/mcp/          MCP adapter on ExMCP (M1)
  lib/avwe_web/          Phoenix channels and LiveView (M2)
  worlds/ember-reach/    terrain, compiled sidecars, snapshots, logs
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
  (section 10.2), and saved. Once accepted, it is fixed and no longer
  regenerated.

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
  systems: [Avwe.Systems.Daylight],    # run in this order every step
  components: %{
    position: %{"mira-vale" => {121, 138}},
    repr:     %{"mira-vale" => %{name: "Mira Vale", description: "..."}},
    body:     %{"mira-vale" => %{species: "riverfolk"}}
  },
  fields: %{temperature: grid, water: grid, fuel: grid, smoke: grid},
  env: %{light: 0.42},                 # region-wide values
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

**Fields are not entities.** Heat, water, fuel and smoke are dense grids
updated by stencil operations (diffusion and flow). They start as tuples or
binaries in plain Elixir and move to Nx when profiling says so.

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
3. Run systems in a fixed order: movement → needs → fire → heat → water →
   weather → autopilot (autopilot queues intents for the next tick, the same
   way any controller does).
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
  default, so a world day lasts 24 real minutes. Systems can run less often:
  weather once an hour, needs every 10 minutes.
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
| Heat | Temperature field, diffusion, heat capacity per material, sun by day, radiation by night | The town "sits where the silt used to steam at dusk". The river's water was warm and heated the silt banks. Once the river is gone, the silt cools through ordinary heat physics, with no second miracle |
| Water | Surface water depth over a heightmap, downhill flow, warm inflow at the source, evaporation driven by temperature | The river running dry: the 812 AR miracle event stops the source, and the river drains from upstream down, so the Dry Bend goes quiet first |
| Fire | Fuel per cell or item, ignition temperature, burning consumes fuel and produces heat and smoke | "When the river still ran, heat was easy to invite. After the River Runs Dry, many chimneys went cold." Households that keep the Hearth Compact only light a fire that is invited, meaning one that would catch easily. As the silt cools, fewer fires are invited. Smoke can be seen and smelled at a distance |

**Conservation invariants as tests:** each tick, the world's water and energy
budgets balance against declared inputs (rain, inflow, sun, miracles) and
outputs (evaporation, outflow, radiation). Property tests check this.

### 6.7 Persistence

- An append-only log per world: applied inputs plus chronicle-worthy events.
- A snapshot every N ticks (`:erlang.term_to_binary`) under
  `worlds/<id>/state/`.
- Files are enough to start. SQLite or Postgres come later if needed.

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

- Each body has at most one **active controller**. Others can watch as
  spectators.
- Controller kinds: `:autopilot`, `:human`, `:arbor`, `:mcp`.
- When a controller disconnects or stays idle past a timeout, autopilot takes
  the body back. The body keeps living either way.
- Autopilot is a controller like any other. It uses the same intent API, just
  running inside AVWE.

### 7.2 Autopilot

A utility AI over needs (rest, warmth, food, water, social) plus **routines**
compiled from the body's Quire article (section 10.3). Mira Vale's routines:
walk the banks before dawn, survey, stop at the lodge on the way home to warm
her hands. Beliefs adjust utilities. An Ashwarden will not let the Last Coal
go cold and will stop anyone carrying it down the hill. A household that keeps
the Compact won't force a fire that hasn't been invited. Autopilot doesn't need
to be clever, only believable over long stretches of history mode.

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
  the old channel until dusk, return.
- A `stop` intent ends the current action (`interrupted`, reason `stopped`).

**Built so far:** `go` (to a known place), `wait` (for a duration, or until
dawn or dusk), `say` (whisper, talk or shout) and `stop`. Plans and `until`
conditions on other verbs come with M1.

### 7.4 Salience and interrupts

Every percept gets a **salience** from 0 to 1, computed for each observer from
loudness, distance, novelty, threat, and whether it was addressed to that body.
Each controller sets a threshold. A percept above the threshold interrupts the
current intent and wakes the mind. That is how slow minds (an LLM taking
seconds) coexist with a fast clock: the body carries out long intents on its
own, and the mind is only called when something matters.

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
| Sight | 50 m at night, about 500 m at noon. Blocked by terrain and walls (once there is terrain) |
| Hearing | Range set by volume: whisper about 2 m, talk about 15 m, shout about 100 m |
| Smell | Carried by wind. Smoke is the main thing to smell |
| Touch | Temperature of the cell or place, wet or dry underfoot |
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

### 8.5 Transports

| Transport | Used by | Notes |
|---|---|---|
| TCP line protocol (telnet) | Text client | Percepts rendered as prose on the server, MUD-style commands parsed into intents |
| Phoenix Channels (WebSocket) | Web client, Arbor | JSON messages as above |
| MCP (ExMCP, streamable HTTP) | Claude | Tools described in section 12 |

## 9. Clients

| Client | Milestone | Description |
|---|---|---|
| Text (telnet) | M0 | `look`, `go dry bend`, `say ...`, `wait until dusk`. The quickest way to be in the world |
| MCP | M1 | Claude plays a body |
| Web | M2 | LiveView page with a canvas hook. **Embodied view** shows what your body perceives. **Spectator view** shows everything, with overlays for heat, water and smoke |
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

One MCP session holds one controller lease. Mira Vale is the first body.

| Tool | Behavior |
|---|---|
| `look` | Current percepts, affordances, time of day and weather |
| `act(verb, target, params, until)` | Blocks across world time until the action finishes or is interrupted, or until a real-time cap (about 60 s) returns progress. Returns the percepts gathered on the way |
| `say(text, volume)` | Speak at whisper, talk or shout volume |
| `wait(until)` | Let time pass until a condition is met or something salient happens |
| `status` | Body state: needs, inventory, location |

Between sessions, autopilot drives the body. When Claude reconnects, `look`
opens with "while you were away", built from chronicle events the body
actually perceived.

**Memory lives in the world.** Mira's survey notebook and map are in-world
items. Writing in them is an in-world action, and reading them next session is
how Claude remembers. The world provides persistence the model doesn't have.

## 13. Milestones

**Testing rule:** every user- or agent-facing feature has an end-to-end test
through its real transport: telnet over TCP, sessions as agents use them, MCP
over its transport, Arbor through its capability. Unit tests are for the pure
core. A feature isn't done until its end-to-end test exists.

| | Name | Scope | Done when |
|---|---|---|---|
| **M0** | The valley breathes | Mix project. Read-only Quire import. One region holding the whole valley. Terrain from pins, including the river's source. Heat, water and fire systems. Places for the lodge and kiln-houses. Mira and a few riverfolk on autopilot. Day and night. Telnet client with `look`, `go`, `say`, `wait`. Log and snapshots | Two telnet sessions see the same events. Replaying the log reproduces the same state hash. Conservation property tests pass |
| **M1** | Claude walks the banks | MCP adapter. Leases. Intents that take time, interrupts and salience. Notebook item | Claude plays Mira across two sessions and finds the notes from the first |
| **M2** | Many lenses | Phoenix and a LiveView canvas. Representation layers. Embodied and spectator views with field overlays | A telnet player, a web player and Claude are in the world at once and each perceives the others |
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

**Open**

1. **Time scale.** Is one tick per world minute at 1 Hz right for both play and
   LLM pacing? What step size does history mode use (section 6.5)?
2. **Resolution.** Are 10 m outdoor cells plus places for interiors enough?
3. **Fiction domain.** Does the disclosure proposal in 11.4 fit Arbor's memory
   model?
4. **Canon versus live play.** Canon is fixed up to 813 AR. Can a controlled
   body diverge from its article afterwards (Mira deciding to carry the coal)?
   Should articles that the chronicle contradicts get flagged in Quire?
5. **Persistence.** Files to start, but when does SQLite or Postgres become
   worth it?
6. **Autopilot.** Is a utility AI enough, or will history mode need
   goal-oriented planning to produce interesting chronicles?

## 15. Prior art

- **Dwarf Fortress**: material and temperature simulation, legends mode, and
  history generated before play begins.
- **MUDs**: rooms, text clients, and the line between in-character and
  out-of-character speech.
- **Generative Agents** ("Smallville", Park et al. 2023): LLM-driven
  characters in a shared town.
- **SpacetimeDB**: a simulation server where clients subscribe to the world.
- **ECSx and Ecspanse**: Elixir ECS APIs to borrow from (section 6.2).
