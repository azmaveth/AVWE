# AVWE engines and rulesets: one simulator, many worlds

> Written 2026-10-08 from a talk with Hysun the same day, docs/DESIGN.md
> sections 1 to 8 and 10 to 13, docs/m3-spec.md, and the code as it stands
> after M3a (master at `95da56b`); revised the same day, twice, after his
> answers to its open questions and a talk about the layers. Where this spec
> and DESIGN.md differ, this spec wins and DESIGN.md is updated afterwards.
> Names of modules and fields are proposals; the behaviour is the contract.

**Decisions** (Hysun, 2026-10-08):

1. **A general-purpose simulator.** AVWE can run earth-like, fantasy, sci-fi
   and entirely new worlds. A world is a **ruleset** (the mudlib: the set of
   rules it runs) and the **data** that says how: its parameters, map,
   entities and characters. One file, the **world definition**, holds both.
   Quire is the source that an LLM compiles into the world definition
   (`docs/quire-spec.md`).
2. **The line for what an LLM may produce: data, and vetted rule code; never
   runtime code.** The LLM writes world definitions, which are validated,
   reviewed and hashed. A world that needs a mechanic no rule has gets it the
   way any code gets in: the LLM may draft a rule and its property tests, and a
   person reviews it like any pull request.
3. **Spatial scope of v1: a 2D grid and a place graph.** Other topologies (3D,
   orbital, continuous) wait.
4. **Start with this spec**, then the world definition as data (E1, below).
5. **Separate projects from the start**, in sibling directories of this
   repository, each with nothing shared (no config, deps or build), with
   one-way dependencies so the compiler enforces the boundary. Extracting from
   one project later is the harder direction.
6. **Definitions are JSON.**
7. **Composition by granular rules.** A world runs a ruleset: the rules it
   lists, or a named preset, with the ones that do not apply left out. Rules
   declare what they own, provide, need and run after, and the engine checks
   the whole when the world loads (4.2).
8. **Names and units stay.** "Ruleset" is the name. A minute is 60 seconds and
   an hour 60 minutes; a world that needs other units can redefine them
   later.
9. **Later:** a scene for place graphs, to be revisited with 3D space.
10. **Two engines, with rules above both.** **sim** is how a world evolves (the
    simulation kernel); **play** is how anyone lives in it (bodies, control,
    intents, percepts, projections). They are separate projects, `avwe_sim`
    and `avwe_play`. A rule is a **model** (needs only sim) and, if it has one,
    an **embodiment** (needs play). `avwe` is the platform on top.
11. **Norms in v1 are code**: a named predicate a rule provides, which a
    definition attaches to a body. A data form for cultural norms waits until a
    world needs one.
12. **The long-term shape is recorded, not built** (section 11): the engine
    should be able to grow into a 3D, real-time, MMO-scale simulator with
    per-client projections, and nothing here may close that door.

Defaults accepted (no preference given, or taken from my recommendation):
archetypes (species) become a definition section when a second world needs
them; rules declare the shapes of the components they own; a capability is a
state key, a pure query, or both; the adapters (MCP, telnet, web) stay in the
platform project for now.

**Done when:**

- The Ember Reach runs from a world definition and the `earthlike` ruleset,
  and `avwe_sim` and `avwe_play` name nothing Earth-like. The golden journal,
  recorded from the Ember Reach before any of this, replays to the same events
  and the same state after all of it.
- A second, deliberately different world (section 7, a space station) runs on
  the same engines with rules of its own, telnet and MCP play it with no change
  to either adapter, and the web page plays it through its text view.
- The scripted reference agent (`Avwe.Test.ReferenceAgent`), told only what
  the protocol says, plays both.

## 0. What exists, and what does not

The engine is already general in the places that matter most. The `:systems`
option makes the rules a list of modules; the journal and replay, the wire
form and the adapters know nothing of heat or rivers. What is not general is
everything that was written for the Ember Reach and put in the same folders. Of
the 14,200 lines in `lib/` outside the web client, the six physics systems
alone (`Heat` 877, `Smoke` 424, `River` 293, `Fire` 284, `Weather` 120,
`Daylight` 70) are about 2,070. Around them:

- **The physics does not depend on the agent layer; the agent layer depends on
  it.** Four of the six systems (`Daylight`, `Weather`, `River`, `Heat`) refer
  to no body, intent or percept. `Fire` stores an id for who lit a hearth.
  `Smoke` walks the bodies to work out who smells what, a sense living inside a
  physics module. There is no shared physics substrate either: heat is cell
  arrays, smoke is drifting particles, the river is a chain of reaches, fire is
  entities. They share only region state, the step length, `Tick.rng/2`,
  events and the space's geometry.
- **The stepping core knows about agents in five places.** `Region` dispatches
  intents straight to `Actions`; its inbox and `Store`'s journal are typed
  `Intent`; `RegionServer` validates guest arrivals (`Guests.check`), releases
  the bodies whose lease is gone when a region resumes, and warns about
  characters that differ from the saved world.
- **Verbs are one function.** `Avwe.Actions.perform/3` has a clause per verb.
  Three of the thirteen verbs are Earth-like (`kindle`, `douse`, `follow`). The
  MCP server's verb list (`Avwe.MCP.Steps`) and the telnet words
  (`Avwe.Command`) are written out by hand.
- **Senses are one module.** `Avwe.Perception` (959 lines) calls `Fire`,
  `Heat`, `River` and `Smoke` directly, holds the hearing table, and builds
  the look. `Avwe.Prose` (524) writes English with Earth thresholds (15 °C is
  "cool").
- **Autopilot mixes a mechanism with content.** The mechanism (a decision per
  step, utility pick, plans, routine windows with missed and too-late
  handling, jitter) is general. The candidates (kindle at home, stay by the
  fire, go to a fire, rest in the dark) and the `invited_fire` norm, which
  reads the river bed's temperature, are the Ember Reach.
- **Terrain is a river valley.** `Avwe.Terrain` is a channel, reaches, silt
  and clay; `GroundMap`, `WorldGround`, `Overlays` and `WorldScene` assume it.
- **Time and space are constants.** `Avwe.Calendar` is 365 days of 24 hours
  counted in "AR"; `Avwe.Space` is a grid of 10 m cells with eight compass
  directions.
- **Systems are named by module.** `Region.systems` holds module names, which
  are part of `Region.state_hash/1` and of every snapshot, so renaming a
  module would break a saved world.
- **The physics is already cut into parts, but the parts call each other by
  name.** Each system writes only its own state (`Daylight` the `light` value,
  `Weather` `air_c` and `sky_c`, `River` the `:river` component, `Fire` the
  `:hearth` component, `Heat` the heat field, `Smoke` the smoke field). The
  edges between them are six direct calls: `River` into `Weather`; `Heat` into
  `Daylight`, `Fire`, `River` and `Weather`; `Smoke` into `Fire`. `Perception`
  and `Autopilot` call the same modules.
- **The engine reads Quire.** `Avwe.start_world/2` loads a Quire folder, and
  `Avwe.Quire.Seed` makes the places and bodies from it. Guests learn "pinned
  places" by testing for an `:article` component, a Quire idea.

## 1. Layers

Like an LPMud's driver, mudlib and areas (RimWorld's data "Defs" and
Ranvier's bundles are relatives of the same split), with the driver in two:

```text
 platform  avwe            loads worlds · compiles Quire · adapters (for now) · harness
 world     definition      JSON: ruleset, parameters, map, entities, characters
 rules     avwe_earthlike  each rule = a MODEL (systems, state, queries)
           avwe_station      + an EMBODIMENT (verbs, senses, behaviours, vocabulary)
 ───────────────────────────────────────────────────────────────────────────────
 play      avwe_play       bodies · control · intents and results · percepts ·
                           sessions · protocol · the autopilot mechanism · projections
 sim       avwe_sim        ticks · state · space · calendar · systems · events ·
                           persistence and replay · rule loading and composition
```

| Layer | What it is | Knows | Does not know |
|---|---|---|---|
| **sim** | How a world evolves: time and ticks, state (`Region`: entities, components, fields, env), the space, the calendar, systems, events, rule loading and the composition check, the definition loader, persistence and replay. Extended by registration: systems, input handlers, submit-time validation, resume hooks, definition sections | Ticks, state, systems, inputs, events | Bodies, perception, any physics |
| **play** | How anyone (a person, Claude, an Arbor agent, an NPC) lives in a world: bodies, control and leases, intents, verbs and results, durative actions, percepts and senses, look and affordances, memory, discovery, guests, the autopilot mechanism, the wire protocol, sessions and minds, and the **projections** (prose, scenes, representation layers; 4.10). The first thing that registers with sim | Bodies, intents, percepts | Any physics, any world |
| **rules** | A **rule** is one self-contained feature of a world (`fire`, `smoke`, `river`, `atmosphere`). Its **model** owns state and has systems and queries; its **embodiment**, if it has one, brings the verbs, senses, behaviours and vocabulary by which bodies meet it. Rules ship in **rule packages**, with named **presets** | Sim (models), play (embodiments) | Adapters |
| **world** | A world definition: the ruleset it runs (the rules it lists, or a preset), their parameters, the calendar, the space, the map, the entities, the characters and their routines, scheduled changes. One file per world | Rules | Code |
| **platform** | `avwe`: loads worlds, compiles Quire into definitions, runs the adapters (for now), the run harness, the chronicle | Everything below | |

Dependencies point one way: platform, rule packages, play, sim. A rule's model
needs only sim, so it can be tested, calibrated and dry-run without a single
session, and reused by a world with no bodies. A world names rules, a rule may
need what another provides (4.2), and neither engine names any of them. The
protocol's shape belongs to play and is the same for every world; its
**vocabulary** (verbs, modalities, event types) comes from the world's rules.

Quire is not a layer. It is the source of the compile step that makes a
definition (`docs/quire-spec.md`), and the engines never read it.

## 2. What an LLM may produce

This is decision 2, written as rules.

- **It writes definitions.** JSON in a schema the rules publish. The loader
  maps strings to atoms through tables a rule declares, never with
  `String.to_atom/1`, because the file is untrusted input.
- **It does not write code that runs in a world.** LLM-written physics would
  have no conservation tests and no replay guarantee, and would be arbitrary
  code in the BEAM.
- **A new kind of mechanic goes through the front door.** The LLM may draft a
  rule together with the property tests that state what it conserves; the
  draft is a pull request, reviewed and merged like any other, and from then on
  it is a vetted rule.
- **Every generated parameter carries its evidence.** The article and the
  words it came from, or a flag that the value is invented ("canon gives
  only the year"). Reviewers read evidence, not just numbers, and a value a
  person sets is **pinned**: regeneration leaves it alone.
- **The simulation never calls an LLM**, as in DESIGN's non-goals. A
  controller may (`docs/m3-spec.md`); the tick may not.

## 3. Inventory: where each module goes

| Module | Lines | Goes to | Note |
|---|---|---|---|
| `Region`, `Tick`, `Rng`, `Event`, `System`, `Calendar`, `Space`, `Systems.Miracles` | 671 | sim | The contracts. `Region.systems` holds ids (4.3); inputs go to handlers, not to `Actions` (4.4); `Calendar` and `Space` become behaviours with the Earth defaults (4.8, 4.9); `Miracles` is a scheduled change of any component, which every world can use |
| `Store`, `RegionServer`, `World`, `Clock` | 1,060 | sim | Persistence, replay, running a world. The journal holds opaque inputs; the definition's hash joins the snapshot (5) |
| `Intent`, `Percept`, `Guests`, `Text`, `Protocol`, `Command` | 962 | play | `Guests` stops testing for `:article` (5); `Command` reads the verb table (4.5) |
| `Session`, `Mind` | 1,381 | play | Controllers |
| `Systems.Waiting`, `Movement`, `Discovery`, `Memory`, `Autopilot` | 434 | play | Timed actions, walking over whatever the space gives (speed from the body, not a constant), learning places, body memory ("while you were away"), and the autopilot |
| `Actions` (envelope, `complete/4`, the standard verbs), `Perception` (look envelope, speech, arrival, control, `away`), `Prose` (speech and arrival), `Autopilot` (mechanism) | parts of 458, 959, 524, 763 | play | The standard verbs are `go`, `wait`, `say`, `stop`, `write`, `read`, `control`, `release` and `arrive`; `walk` belongs to the grid space |
| `Scene`, `WorldScene`, `Repr`, `Rle` | 804 | play (projections) | The draw protocol. Glyph tables and ground content come from rules |
| `Telnet`, `MCP`, `AvweWeb` | | The platform, for now | Adapters. Verbs, words and affordances come from the world (4.5, 4.11) |
| `Systems.Daylight`, `Weather`, `River`, `Fire`, `Heat`, `Smoke` | 2,068 | `earthlike`: one rule each (the models) | The physics. `Smoke`'s smell logic moves to its embodiment |
| `Terrain`, `Terrain.Generator`, `GroundMap`, `WorldGround`, `GroundCache`, `Overlays` | 881 | `earthlike.valley` | The ground model of a river valley, behind `Ground` (4.10) |
| `Perception` (fire, smoke, river, heat, steam), `Prose` (those parts), `Repr` glyphs | the rest | The embodiment of the rule that owns each | As perceivers and vocabulary (4.6, 4.10) |
| Verbs `kindle`, `douse`, `follow` | | `fire` (`kindle`, `douse`), `river` (`follow`) | 4.5 |
| Autopilot candidates and `invited?` | the rest of 763 | `fire` (kindle, stay, go to a fire, the invited-fire norm), `daylight` (rest in the dark) | 4.7 |
| `Worldgen` | 413 | Splits | `terrain`, `hearths`, `climate` become the parameters of `valley`, `fire` and `weather`; the rest becomes the definition loader (sim) |
| `Quire`, `Quire.Article`, `Quire.World`, `Quire.Seed` | 355 | The compiler, in the platform, off the run path | Its output is the definition's `entities` |

The line counts are for scale, not for accounting; the table is a plan to be
corrected by the first slice that touches each row.

## 4. The extension points

Each is a behaviour or a table an engine consults. The tables are built once,
when a region is built or resumed, never per step.

### 4.1 Rules: a model and an embodiment

A rule has up to two modules. The **model** implements sim's behaviour and
names its embodiment; the embodiment implements play's. They are separate
modules because they depend on different projects: the model compiles and
tests with sim alone.

```elixir
# sim's: Avwe.Rule
@callback id() :: String.t()                       # "earthlike.fire"
@callback version() :: String.t()
@callback provides() :: [atom()]                   # capabilities, 4.2
@callback requires() :: [atom()]
@callback uses() :: [atom()]
@callback conflicts() :: [String.t()]
@callback owns() :: [key()]                        # {:component, :hearth}, {:field, :heat}, {:env, :light}
@callback runs_after() :: [String.t() | atom()]
@callback runs_before() :: [String.t() | atom()]
@callback systems() :: [{String.t(), module()} | {String.t(), module(), keyword()}]
@callback parameters() :: schema                   # what a definition may set
@callback seed(Region.t(), params :: map()) :: Region.t()
@callback invariants() :: [{String.t(), (Region.t() -> boolean())}]
@callback facets() :: %{atom() => module()}        # %{play: Earthlike.Fire.Play}

# play's: Avwe.Play.Embodiment
@callback owns() :: [key()]                        # {:component, :nose}
@callback requires() :: [atom()]
@callback uses() :: [atom()]
@callback systems() :: [{String.t(), module()}]    # a system that watches bodies, such as smell
@callback verbs() :: [module()]
@callback perceivers() :: [module()]
@callback behaviors() :: [module()]
@callback vocabulary() :: map()                    # prose tables, glyphs, moments
```

Only `id/0` and `version/0` are required of a model. `seed/2` builds the rule's
part of the starting state from its parameters (terrain, fields, hearths).
`invariants/0` is what the rule conserves (the water, the heat, the smoke); the
conformance suite (6) runs them as properties. A system may carry options,
`every: seconds` among them (4.3). `facets/0` is how sim stays ignorant of
play: it hands each facet to the layer that registered for it, and a later
layer (a `view`, section 11) would register its own.

A **rule package** is a Mix project that lists its rules and its presets:

```elixir
@callback rules() :: [module()]
@callback presets() :: %{String.t() => [String.t()]}   # "earthlike" => [rule ids]
```

### 4.2 Composition

A world runs the rules its definition lists, or a preset (`earthlike` is
`play`, `daylight`, `weather`, `river`, `fire`, `heat`, `smoke` and `valley`),
with rules added or left out. `sim` always runs; `play` is listed by every
world that has bodies. A rule that does not apply is simply not listed. What
makes that safe is that every rule says what it touches, and sim checks the
whole when the world loads:

- **Ownership.** A rule owns the state keys it writes: components, fields and
  `env` values. Two rules owning one key is a load error. A rule that wants to
  affect another's state does not write it; it feeds it, through components
  on entities of its own (a hearth is an entity of the `fire` rule with a
  heat source that `heat` reads) or through events. Emit, don't edit.
- **Needs, by capability.** A rule names what it needs by capability, not by
  rule: `provides: [:air_temperature]`, `requires: [:air_temperature]`,
  `uses: [:water_seepage]`. An unmet `requires` is a load error; an unmet
  `uses` means the rule runs without it (heat in a world with no river has no
  seepage). A capability is a state key, a pure query, or both, so `smoke`
  needs `:wind` and works with any weather rule that provides it, and a world
  with other weather leaves `earthlike.weather` out. The six direct calls in
  section 0 become capabilities; that is the work of E3 to E5. Queries are
  called through a table built at load, not by module name.
- **Order.** A rule says what it runs after or before; sim sorts all systems
  deterministically (ties by id). A cycle is a load error.
- **Names.** System ids, verb ids, behaviour ids and modalities are unique in
  a world; a clash is a load error naming both rules.
- **Conflicts.** A rule may name rules it cannot run beside (two ways of
  modelling the same thing).

All of it is refused at load, all problems at once, in plain words:
"earthlike.smoke needs :wind, which no rule in this ruleset provides
(earthlike.weather does)".

The two engines are rules themselves, so the check treats them like any other.
**`sim`** owns `position`, `place` (the named locations of a space) and
`miracle`, and runs the scheduled changes. **`play`** owns `repr` and the
components of bodies and what they carry (`body`, `control`, `action`, `knows`,
`memory`, `notebook`, `item`, `carried_by`, `autopilot`, `routine`, `norms`,
`guest`) and provides the standard verbs, the speech and arrival perceiver, and
the systems every world with bodies uses (timed actions, movement, discovery,
memory, the autopilot mechanism).

**Granularity.** A rule is the smallest feature that owns state or a verb and
that a world could sensibly leave out. The test is "could a world omit it?"

**What composition does not promise.** That an arbitrary subset is good
physics. Each rule's invariants run on their own, with the capabilities it
uses stubbed; a preset is tested as a whole (6). A hand-made ruleset gets the
structural check and each rule's invariants, and its author owns the rest.

### 4.3 Systems and their ids

`Avwe.System` is unchanged: a pure `run(region, tick)` that returns
`{region, events}`, with `prepare/1` optional. What changes is the name. A
system has a stable id, qualified by its rule (`earthlike.heat/step`), a region
lists ids, and the module is resolved from the rule when a world is built or
resumed. So moving or renaming a module does not break a saved world, and the
id, not the module, is what `state_hash/1` sees. A resume that finds an id no
rule knows is refused in plain words. Changing what a system does is still a
rules change: the region is snapshotted at once, as it is today.

A system may declare a **period** (`every: seconds`). Sim runs it in a step only
when the step reaches a multiple of the period (`Tick.crossed?/3`), so the
choice depends on time, never on counting steps, and replay is unchanged. The
default is every step. Systems already use the step length and never assume a
minute, so a world with a 20 ms step and a world with a one-minute step are the
same kind of thing.

### 4.4 Inputs: what sim knows of the outside

Sim knows that things arrive from outside the world and are applied at the
start of the next step; it does not know what they are. Play's intents are one
kind. Four hooks replace the five places where the stepping core knows about
agents today:

```elixir
# Avwe.Input, a protocol on the input's struct
def handle(input, region, tick) :: {Region.t(), [Event.t()]}   # replaces Region -> Actions
def order_key(input) :: term()          # applied sorted by {order_key, seq}; play's key is the body
def validate(input, region) :: :ok | {:error, term()}          # at submit, before it is journaled (guest arrivals)

# registered by a layer
@callback on_resume(Region.t()) :: [input]   # inputs to submit and journal when a region comes back (release orphaned bodies)
```

The journal records inputs as opaque terms with the `seq` the region gave them,
as it records intents today, so replay is unchanged. The fifth place, the
per-setting warnings when a resumed world's settings differ from its saved
state, is replaced by one comparison: the definition's hash (5).

A second kind of input can be added without touching sim: **continuous
control** (a held steering vector, a stick), which is state that a body's motor
layer reads each step and not an intent with a result (section 11).

### 4.5 Verbs (play)

```elixir
@callback id() :: atom()
@callback params() :: schema                       # checked before submission
@callback kind() :: :instant | :durative
@callback perform(Region.t(), Intent.t(), Tick.t()) :: {Region.t(), [Event.t()]}
@callback affordances(view :: map(), body :: String.t()) :: [map()]
@callback describe() :: %{summary: String.t(), params: [map()]}
```

Play's handler for intents keeps the envelope: the body exists, exactly one
result event per intent, `:unknown_verb` for a verb the world does not have, and
the `:action` component and `complete/4` for durative actions. The verb supplies
the rest. Intents carry the verb's atom and are journaled as they are now, so
the journal format does not change. The standard verbs come with `play`; the
space contributes the verbs that depend on it (`walk` on a grid); an embodiment
adds its own (`kindle`, `douse`, `follow`). Adapters read the verb table: the
MCP server's `act` schema and instructions, the telnet words, and the look's
affordances are generated from it.

### 4.6 Senses (play)

```elixir
@callback modalities() :: [atom()]
@callback perceive(view :: map(), body :: String.t(), Event.t()) :: [Percept.t()]
@callback look(view :: map(), body :: String.t()) :: map()   # a section of the look
```

`Perception.look/2` and `percepts/3` become a composition: `play`'s perceiver
first (the body, what it is doing, speech, arrival, control, the bodies in
sight, `away`), then each embodiment's in order. Modalities are an open set; a
client treats an unknown modality, type or data key as the world's own words
(the protocol already says every field but a player's text is), and the
reference agent's sorting by structure does not change. Ranges are in metres
and come from the space (4.9), so a rule that hears at 15 m means the same on
a grid and on a graph. A perceiver asks who is near with `Region.near/4`
(4.9), never by scanning every entity.

### 4.7 Behaviours (play)

```elixir
@callback id() :: atom()
@callback candidates(Region.t(), Tick.t(), body, record :: map()) :: [candidate()]
```

The mechanism stays in play and calls every enabled behaviour for a body that
nobody drives. A behaviour is enabled by the definition (per world or per body)
and takes its numbers (thresholds, utilities, the invited temperature) from its
rule's parameters. Candidates keep their present shape (`%{utility, intent,
why}`), so the tie-break order, the urgent interrupt and the plan rules do not
change. The routine a body follows is data in the definition. The Sims' pattern
(needs, what satisfies them, utility curves as data) is a later step, and the
station is where it would first pay (section 7); it is not in v1.

**Norms** (decision 11) are named predicates, `fn region, body, subject ->
boolean` that a rule provides as a capability (`earthlike.fire` provides
`invited_fire`, which reads the river bed's temperature through `heat` and
`river`), and a definition attaches by name to a body. Only the autopilot
consults them today.

### 4.8 Calendar (sim)

World time stays an integer count of seconds, and a minute and an hour stay 60
seconds and 60 minutes (decision 8). What becomes data is the day (hours), the
year (days), the epoch's label ("AR"), month and season names, and the **named
moments** (`dawn`, `dusk`, or `shift_change`): each a rule for a time of day,
from the sun in `earthlike` or a fixed hour on a station. The calendar is a
value on the region and reaches systems through the tick, so `Tick.crossed?/3`
and `Calendar.time_of_day/1` work on any day length. The Earth calendar is the
default, and call sites move to the tick's calendar as the slices touch them.

### 4.9 Space (sim)

`Avwe.Space` becomes a behaviour:

```elixir
@callback distance(loc, loc) :: float()                  # metres
@callback direction(loc, loc) :: String.t() | nil        # a bearing, for prose
@callback path(loc, loc) :: {:ok, [loc]} | :error
@callback along([loc], covered :: float()) :: loc        # metres along a path
@callback valid?(loc) :: boolean()
@callback raycast(loc, loc) :: :clear | {:blocked, loc}  # optional
```

A `position` component holds a location the space understands. v1 ships two:
`Space.Grid` (today's: cells, 10 m a side, eight compass directions, `walk`) and
`Space.Graph` (places joined by edges with lengths in metres; doors are
entities on edges; a location is a place id). A world uses one. A hybrid, a
grid outdoors with graph interiors, is the next step and the station does not
need it.

**Who is near** is a question of the region, not a scan:
`Region.near(region, loc, radius_m, components) :: [entity_id]`, sorted. It
scans today; it may use an index later without any caller changing. Hearing,
sight, "at a place", discovery and the audience of a speech use it instead of
`with_components/2` plus a filter. Movement uses `path/2` and `along/2`. Line of
sight and walls are a perceiver's business, with `raycast/2` where the space
offers one.

### 4.10 Ground, vocabulary and projections (play)

`Region.terrain` stays an opaque slot, owned by a rule's `Ground` module
(a play behaviour): elevation, ground class, whether a cell can be walked, the
palette a scene draws it with. A world with no ground (a station) leaves it
empty.

Prose and glyphs are rule tables. Play keeps the words only it needs: speech
verbs, arrival and departure, control hand-over, refusals. English is the only
language in v1; the tables are where another would go.

**Projections** are what the world shows a client: percepts and the look (the
semantic form, for agents), prose (for telnet and the page's log), the scene
(for anything that draws), and later a replication stream. Each is a pure,
read-only function of a body's view, derived and never stored, so the journal,
the snapshots and the state hash do not know they exist (DESIGN 8.4). They live
in play, and the dependency runs one way: a projection reads percepts, never
the reverse. That is the **view** (section 11).

### 4.11 What a client can ask a world

One addition to the protocol: a world **describes** itself. The verbs with
their parameters, the modalities, the calendar and the units, and the rules
with their versions. In MCP it is the server instructions and the `act` tool's
schema, generated from the verb table; in telnet, `help`. A client that has
never seen the world can play it, and nothing in the wire form of a percept or
a look changes: the keys that exist stay, and a world may add `data` keys of
its own.

## 5. The world definition

One JSON file per world, `priv/worlds/<name>/definition.json` (E1 as built:
`worlds/` is where a running world keeps its journal), beside the evidence that
produced it (`provenance.json`) and the Quire snapshot it was compiled from
(`docs/quire-spec.md`). The table is the plan; "E1 as built" in section 8 says
where the first slice differs from it.

| Section | Holds | Registered by |
|---|---|---|
| `schema`, `id`, `name`, `tagline`, `description` | Identity and the schema version | sim |
| `ruleset` | A preset and the rules added or left out: `{"preset": "earthlike", "without": [], "with": []}`, or an explicit list of rule ids | sim |
| `rules` | By rule id, what each is told (terrain spec, hearths, climate, thresholds) | each rule's `parameters/0` |
| `calendar`, `space`, `start`, `seed`, `dt` | The calendar spec; the space and its map (grid size, or the place graph); the world time to start at; the seed; the length of a step in world seconds | sim |
| `entities` | Places, bodies, items, with their components in shapes the rules declare. What `Quire.Seed` builds today | sim |
| `scheduled` | Miracles and other scheduled changes | sim |
| `characters` | By body id: routine, norms, carried items, behaviours, glyph and colour | play |
| `guests` | Where guests arrive, how many, and which places they know on arrival (a tag in `entities`, not `:article`) | play |

How the clock is run (`clock`, `data_dir`, snapshot intervals) stays a start
option: it is how a world is run, not what it is.

**Loading** validates the whole file against the schemas the layers and rules
publish (unknown keys, bad values and unresolved ids are refused, all of them at
once, in plain words), checks the composition (4.2), and then builds the region:
sim's entities, then each rule's `seed/2`, then each system's `prepare/1`.
`Worldgen`'s checks (a hearth needs fuel at least zero and power above zero; a
routine step must be a verb the body can do) become schema rules, with the same
messages.

**Replay.** The definition's hash is part of the starting state: it is kept
in the snapshot and in the log's header, so a replay that finds a different
definition refuses, and a world can say which definition it came from. The
log's records are otherwise unchanged.

**Provenance** is outside the hash: the evidence behind each value (article,
quote), whether it is invented, whether a person pinned it. Regenerating
after canon changes produces a **diff** against the last accepted definition,
recomputed only for the articles whose hash changed.

## 6. Projects, versions and conformance

Five kinds of Mix project, in sibling directories of this repository, each with
its own `mix.exs`, lockfile, tests and CI job, and no shared config, deps or
build (that sharing is what makes an umbrella hard to take apart):

| Project | Is | Depends on |
|---|---|---|
| `avwe_sim` | The simulation kernel (section 3, sim). No body, no percept, no Earth-like word | Nothing of ours |
| `avwe_play` | The agent layer and the projections. No Earth-like word | `avwe_sim` |
| `avwe_earthlike`, `avwe_station`, ... | Rule packages: models and embodiments, and their presets | `avwe_sim` (models), `avwe_play` (embodiments) |
| `avwe` | The platform: definitions (`worlds/`), the Quire compiler, runtime config, the adapters for now, the run harness, the end-to-end tests that need a real world | Everything above |

Dependencies point one way, so the compiler enforces the boundary: sim cannot
call play, and neither can call a rule, because each depends on it. Inside a rule
package, which depends on both, the compiler cannot tell a model from an
embodiment, so the conformance suite checks that no model module references play
(an xref check). A **words test** in `avwe_sim`
and in `avwe_play` covers what the compiler cannot see: it fails on any source
file that uses `hearth`, `river`, `smoke`, `silt` or `kiln`, and sim's also
fails on `body`, `percept` and `intent`.

**The direction of extraction.** The engines move out of the current project; the
rules do not move out of the engines. The current project depends on `avwe_sim`
from E2 and on `avwe_play` from E3, and neither depends on it; modules move into
them as their seams close and they stop naming Earth-like code, each with its own
tests. What is left in the current project at the end is the Earth-like rules and
the runnable world, which E7 splits into `avwe_earthlike` and `avwe`. A rule
package cannot be test-depended on by the engine it extends (the cycle), which is
why each engine's own tests run on test code: sim's on small test systems and a
test input handler, play's on a small test rule (the standard verbs, a constant
light, no physics).

**Tests move with the code they are about.** Sim's suite covers the region, the
tick, determinism, the journal and replay, the composition check and the
definition loader. Play's covers sessions, guests, words, notebooks, the
protocol, the autopilot mechanism and the projections. The physics, fire and
smoke end-to-end tests, the autopilot's fire behaviours and the river watchers go
with their rules, and the journeys that need the whole Ember Reach
(`three_controllers`, `persistence`), MCP, telnet and the page go to `avwe`.
Nothing is deleted without a test that covers the same thing in its new home.

**Versions.** Each engine has an API version; a rule package says which it was
written for, and a mismatch is refused at load. A rule has a version, recorded
in the definition and the saved region. A resume with a different major
version is refused unless the rule offers a migration; a different minor
version is a rules change (snapshot at once).

**The cost, plainly.** Four or five lockfiles, CI jobs and Dialyzer PLTs instead
of one, `mix` commands run per project (a root script runs them all), and paired
changes while the seams are still moving. That is the price of a boundary the
compiler holds.

The **conformance suite** runs against every rule, and every preset, the
station's included. Sim hosts the model half (`Avwe.RuleCase`), play the
embodiment half:

- every system is a pure function of the region and the tick (the same region
  gives the same `state_hash/1`, however the steps are grouped);
- no system draws from `:rand` without `Tick.rng/2`, and none reads the wall
  clock or does I/O (an xref check on the compiled module's calls);
- a system changes only the state keys its rule owns (checked by running it on
  generated regions and diffing);
- the rule's `invariants/0` hold over generated worlds and step lengths;
- every verb ends each intent in exactly one result event (the existing
  property test, over the world's own verbs);
- every perceiver is pure and never returns player text outside the places the
  protocol allows (`Avwe.Protocol`'s check);
- a model runs, and its invariants hold, in a region with no bodies and no play.

## 7. The forcing world: a space station

A generality that has one user is a guess. The station is a small, deliberately
different world, a test fixture first (a rule package `avwe_station` and a
definition, both under test), promoted to a real ruleset if it earns it. It
exists to make each seam fail in an unfamiliar way:

| Seam | What the station does differently |
|---|---|
| Space | Five rooms joined by corridors and doors (a place graph), no grid |
| Calendar | A 20-hour day with a `shift_change` moment, no sun, no dawn |
| Rules | `power` (generation against demand, brownouts) and `atmosphere` (oxygen per room, leaks through open doors, scrubbers that draw power, which `uses` the `power` capability). Both conserve (oxygen made and stored equals consumed and vented; power balances). Neither knows `fire` or `weather` exists, and both run, tested, in a region with no bodies |
| Verbs | `repair` (durative), `seal` and `open` (instant, on doors), beside the standard `go`, `say`, `wait`, `write`, `read` |
| Senses | Sight by room and by light; hearing through open doors; a new modality, `instrument`, that reads gauges into a section of the look |
| Behaviours | Crew routines by shift; `evacuate` when the oxygen in a room falls; `restore_power` |
| Characters | Three crew, a routine each |

What it must prove: no change to the telnet or MCP adapters, and the web page
working through its text view; the reference agent plays it from the protocol
alone; the golden journal and replay hold for it as for the Reach; the step
stays inside the performance bound; the composition check refuses a station
ruleset missing `power`, in plain words; and the engines needed no change that
was not one of the seams above. If they did, that is the finding, and the spec
is corrected.

## 8. Slices

Each slice is one or a few pull requests, ends green on the whole suite, and
changes no behaviour of the Ember Reach (the golden journal says so), except
where it says otherwise. M3b and M3c are not blocked: the protocol keeps its
shape.

| Slice | Scope | Done when |
|---|---|---|
| **E0** | This spec; pointers in DESIGN and the README | Merged |
| **E1** | **The golden journal** (a recorded Ember Reach run: its intents, its advances, its full event stream and its final state with system ids in place of module names) and **the world definition as data**: JSON schema, loader, `definition.json` for the Ember Reach generated from today's Quire-plus-config path, and `start_world` taking a definition | The old and the new path build equal regions (`state_hash/1`); the golden journal replays identically; the run path no longer reads Quire |
| **E2** | **The kernel.** The rule manifest and the composition check; stable system ids and system periods; the four input hooks (in place first, then moving `Region`, `Store` and `RegionServer` off `Actions`, `Guests` and `Intent`); `Region.near/4`; the calendar as a value with the Earth default. Then the **`avwe_sim` project** is created and receives the kernel modules; the current project depends on it | `mix test` is green in both projects; a saved world resolves systems by id and a renamed module does not break it; the composition check refuses a bad ruleset in plain words; sim names no body, percept or intent |
| **E3** | **Verbs**: the verb table; the **`avwe_play` project** is created and receives `Intent`, `Percept`, `Actions`' envelope, `Command` and the timed-action and movement systems; `kindle`, `douse` and `follow` become their embodiments' verbs; MCP, telnet and the look read the table | Adapters list the world's verbs; the golden journal is identical |
| **E4** | **Senses**: perceivers; `Perception` split into `play`'s and each embodiment's; `Smoke`'s smell logic into its embodiment. `Perception`'s core, `Session`, `Mind`, `Protocol`, discovery and memory move to play | Same percepts, byte for byte |
| **E5** | **Behaviours**: the autopilot mechanism moves to play; the candidates and `invited?` become embodiments' behaviours and capabilities | Same decisions |
| **E6** | **Vocabulary, projections and ground**: prose and glyph tables; `Terrain` and the scene content behind `Ground`. The draw protocol moves to play | Same scenes and prose |
| **E7** | **The split**: what is left of the current project becomes `avwe_earthlike` (the physics as models, with their embodiments, in seven rules and a preset) and `avwe` (definitions, the compiler, adapters, runtime config, end-to-end tests). Tests move with their code; CLAUDE.md, CI and the hooks are updated | Neither engine project names an Earth-like thing; every project is green; the Ember Reach runs from `avwe` |
| **E8** | **Space** as a behaviour with `Grid` and `Graph`, ranges in metres, and **the station** end to end (telnet, MCP, the web page's text view, the reference agent) | Section 7's list, all of it |

E1 and E2 are mechanical and low risk apart from the hooks, which are the one
piece of real design in them; E2 may be two pull requests. E1 and E2 deliver
most of what the Quire work (stage 1) needs. E3 to E6 are where play takes
shape, and E8 is the hardest. The order is by dependence: an engine cannot take
a module until it stops naming Earth-like code, and it cannot stop until the
table that replaces the name exists.

A saved dev world does not survive E1 (the snapshot gains the definition's
hash) or E2 (it refers to modules by name). The snapshot refuses it with the
usual message; nothing else is lost.

### E1 as built

**The golden journal** (`Avwe.Test.Golden`, `test/golden`, recorded files in
`test/fixtures/golden`). Two runs of the Ember Reach, driven as controllers
drive it: `:ember_813` (two world days: Mira lights the hearth, speaks, writes,
walks the banks, follows the channel, says something at every volume, is let go
of; a guest arrives) and `:ember_812` (nobody at the controls, from the
afternoon before the source fails to three days after). For every step it keeps
the events and the percepts a spectator, Mira and the guest are told; every
180 steps each body's look; every 360 steps a digest of the whole state; as
digests, and as the full normalised streams beside them, so a failure names the
first difference. Floats are rounded to 6 significant digits (five decimals
was too fine: macOS and Linux differ in the last bits of `exp`, and the heat
field's large values showed it); `systems` is left out of the state, since E2
changes how a region names them. It matches on macOS and Linux (arm64 and
x86_64). It is re-recorded only by hand, on code whose behaviour is the one to
keep (`MIX_ENV=test mix run -e 'Avwe.Test.Golden.record!()'`); a failure is
read as a bug. Each scenario runs twice, from the region Quire and the
settings build and from the definition.

**The definition** (`Avwe.Definition`, with `Codec`, `Schema`, `Check`, `Json`
and `Export` beside it, all pure; `Avwe.Definitions` reads the files). One file,
`priv/worlds/<name>/definition.json`, schema version 1; the Ember Reach's is
`priv/worlds/ember-reach/definition.json`. What differs from the table in
section 5:

- `rules` is keyed by the rule ids this spec names: `earthlike.valley` (the
  terrain), `earthlike.fire` (the hearths) and `earthlike.weather` (the wind).
  The rules do not exist as modules yet, so the keys are the names E2 will
  give; there is no `ruleset` section, and a world still runs the engine's own
  systems (`Avwe.start_world/2`'s `:systems`), since the systems are code.
- Miracles are one section, `miracles`, with a `kind` (`event`, a change at a
  time; `standing`, a hearth that burns without fuel), where this table says
  `scheduled`. The standing miracle carries its own name and description: it
  has no Quire to ask.
- `entities` holds what `Quire.Seed` builds, flat: `id`, then `place`,
  `position`, `repr`, `article`, `body`, `knows`, `home`. A body that is
  nowhere simply has no `position`.
- `guests` is `{"arrival": place, "max": n}`; `characters` is by body id, with
  `norms`, `carries`, `routine`, `glyph` and `color`. `provenance.json` is not
  built yet.

**Reading is closed.** Every type in the schema is a description
(`Avwe.Definition.Codec`) used to read and to write, so what is written can be
read again. A string becomes an atom only by being one of the names the schema
lists (the verbs a routine step may use, the norms, the item kinds, the
components a miracle may change and what it may set on each, the directions);
object keys are looked up among the keys listed; no atom is made from the
file. Reading reports every problem with its path (`rules.earthlike.fire.
hearths[0].fuel_kg: expected a number, 0 or more, got -1.0`), shapes first and,
when they are right, references (`Avwe.Definition.Check`): an id belongs to one
thing, a place has a position on the map, `home`, `knows`, the terrain, a
hearth, a standing miracle and the guests' door name places, an event's target
exists and has the component it changes, a character is a body and a routine
step's target is something in the world. `Worldgen`'s own checks stay as a
second line, with the same messages.

**The hash** (`Avwe.Definition.hash/1`) is SHA-256 of the canonical form of the
data (keys sorted, no spaces), not of the text: a file laid out differently,
or with its keys in another order, is the same definition. It leaves out
`guests`: who may arrive and where is how a world is run, as its clock is, and
a saved world takes the guests it is started to take (`docs/m3-spec.md`), so
raising the most a world takes does not strand it. `to_json/1` writes
the readable form (`id` and `name` first, a short object on a line), and a test
requires the checked-in files to be exactly what it writes.

**Starting a world** (`Avwe.start_world/2`). `definition:` takes a name (read
from `priv/worlds/<name>/`, or `config :avwe, :definitions_root`), a path to a
`.json` file, or an `Avwe.Definition`. The definition is the whole of the
world, so `:start`, `:seed`, `:terrain`, `:hearths`, `:miracles`, `:climate`,
`:characters` and `:guests` are refused beside it
(`{:settings_with_definition, keys}`); a different world is a different
definition, and a test that wants one changes the struct. `quire:` and its
settings stay for tests and for trying a Quire world; both together is
`:definition_and_quire`, neither `:no_world_source`. The run path of the Ember
Reach (`config :avwe, :worlds, ember_reach: [definition: "ember-reach"]`) no
longer reads Quire.

**Saving.** The snapshot is now `{:avwe_snapshot, 2, %{region: region,
definition: hash}}` (`hash` is `nil` for a world started from Quire), written
at step 0 and every snapshot after, so the first one is the header of the
history that follows (no separate log header was needed). A saved world is
resumed only under the definition it was saved under, however that file is laid
out; under another, or under none, or the other way round, it refuses to start
(`{:definition_changed, saved, given}`), says both hashes and where the world
folder is, and writes nothing. The settings warnings of the Quire path are
unchanged. `Avwe.worlds/0` reports each world's `definition` hash.

**Making a definition.** `Avwe.Definition.Export` compiles one from a Quire
world and a **recipe** (AVWE's own settings for the world: seed, start, terrain,
hearths, miracles, climate, characters, guests), refusing a recipe that does
not make a valid definition, with every problem. For the Ember Reach the
recipe is `priv/worlds/ember-reach/source.exs`, and `mix avwe.definition.export
ember-reach` writes `definition.json` from it and Quire's folder, reads it back,
and stops unless it reads as what was made. A test makes the fixture's
definition again and compares the text; another builds the Ember Reach both
ways, from Quire and settings and from its definition, and requires the same
`Region.state_hash/1`, at four times of day and with the settings changed the
same way. The checked-in definition made from the real Quire is checked against
the fixture's for everything the recipe says. Stage 1 of the Quire work
(`docs/quire-spec.md`) replaces the exporter with a language model whose output
the same loader reads.

**Not in E1.** `ruleset` and rule composition (E2), `provenance.json` and
diffs against the last accepted definition, species as a section, the log
header the spec once planned (the snapshot does that work), and a definition
for Lantern Hollow (the Quire path stays for the tests that use it).

### E2a as built (the kernel in place)

E2 was built in this project first. The kernel stayed in `lib/avwe/` until a test
said it names nothing above itself (below), and moving its files to a project of
their own (E2b, next) was then a move and not a change. What was built:

**System ids and periods** (`Avwe.System`, `Avwe.SystemTable`, `Avwe.Region`).
A system module gives its id (`c:Avwe.System.system_id/0`, `"earthlike.heat/step"`:
the rule, a slash, the name), a region keeps `{id, options}` for each system, and
`state_hash/1` and every snapshot see only those. `SystemTable` (in
`:persistent_term`: it is read for every system of every step) says which module
runs an id. `Region.new/1` registers the modules it is given, `Ruleset.register/1`
those of a plan, and the application registers every system of every rule the
packages ship when it starts; the table also looks there itself, once, before it
says an id is unknown, so a saved world resolves whatever it is started under (it
fills in only the ids it has nothing for, so it never undoes a move: `put/2` is
what says that a system moved).
Two modules that declare one id are refused when the second is registered; a
module that declares none is known as `"module:" <> inspect(module)`, which is
for tests and which a rename changes. A resume that finds an id no rule declares
is refused in plain words (`{:unknown_systems, ids}`), and a renamed module
under an unchanged id resumes. A system listed with `every: seconds` runs in a
step that reaches a multiple of that many seconds, decided by `Tick.crossed?/3`
and so by time and not by counting steps (one advance of many steps and many
advances of one are the same). A step shorter than the period reaches at most one
multiple, and hands the system a tick for the period that ended there (`dt:
every`, ending at the multiple: `Tick.last_occurrence/3`), so the periods it is told
tile time whatever the step, and it sees the region as that step left it; a step as
long as the period or longer hands it the step as it is. The first period of a
region that starts in the middle of one began before the region did. A period is a
whole number of seconds above 0, and a system has no other option: a region refuses
what it cannot run, in words (`Avwe.System.option_problems/2`).

**Rules and the composition check** (`Avwe.Rule`, `Avwe.RulePackage`,
`Avwe.Ruleset`). A rule module implements `Avwe.Rule`: `id/0` and `version/0`,
and what it has of `owns`, `edits`, `provides`, `requires`, `uses`, `conflicts`,
`runs_after`, `runs_before`, `systems` (`{name, module}` or `{name, module,
options}`; the id is the rule's, a slash, the name) and `facets`. `Rule.manifest/1`
reads a module into a map with the defaults filled in. `config :avwe,
:rule_packages` lists the packages (`Avwe.Rules.PlayPackage`, `Avwe.Rules.Earthlike`),
`:default_preset` the preset a definition without a `ruleset` runs (`"earthlike"`);
`sim` (`Avwe.Rules.Sim`) is the kernel's own and always runs. `Ruleset.plan/2`
refuses, all at once, sorted, in plain words: two rules owning one state key; a
`requires` that no rule of the set provides, naming the rules that would
("earthlike.river needs :air_temperature, which no rule in this ruleset provides
(earthlike.weather does)"); rules that conflict; a rule listed twice, or a system
name twice in one rule; a system module whose own id is not the one its rule
gives it; a system listed with a period that is not a whole number of seconds
above 0 or with an option a system does not have; a `runs_after` or
`runs_before` that is no rule, system or capability (a slip, which is not the same
as a rule that was left out: that is not an error); and constraints that cannot all
be met, naming the systems that wait for each other (and not those that only wait
on them). What the constraints leave open is sorted by id, so a ruleset has one order whatever order its rules were
written in. A rule's own systems run in the order it lists them; others say what
they run after, by system id, rule id or capability.

| Rule | Owns | Provides | Requires | Uses |
|---|---|---|---|---|
| `sim` | `place`, `miracle` (and edits any) | `scheduled_changes` | | |
| `play` | `position`, `repr`, `body`, `control`, `action`, `knows`, `memory`, `notebook`, `item`, `carried_by`, `autopilot`, `routine`, `norms`, `guest` | `bodies`, `intents` | | `air_temperature`, `fire_sources`, `light`, `river_water` |
| `earthlike.daylight` | env `light` | `light` | | |
| `earthlike.weather` | env `air_c`, `sky_c`, `wind` | `air_temperature`, `sky_temperature`, `wind` | | |
| `earthlike.valley` | the terrain | `terrain` | | |
| `earthlike.river` | `river`, `spring` | `river_water` | `air_temperature` | `terrain` |
| `earthlike.fire` | `hearth` | `fire_sources` | | |
| `earthlike.heat` | field `heat` | `ground_heat` | `air_temperature`, `light`, `sky_temperature` | `fire_sources`, `river_water`, `terrain` |
| `earthlike.smoke` | field `smoke`, `nose` | `smoke` | `fire_sources`, `wind` | |

The capabilities state what the systems still call by module name (the six
direct calls of section 0); the check refuses a ruleset that leaves one out, and
E3 to E5 route the calls through them. `owns` is what a rule's *systems write*:
`position` is `play`'s because movement writes it, and the places that carry one
are put there when the world is built. The one rule that writes another's state
on purpose is `sim`'s scheduled change, which says so with `edits: :any`. The
check cannot see what a system writes, so a test does (`Avwe.RuleCase.survey/2`
measures what each system changes in its place in the step, over a morning, a
played session and the hour of a miracle, and requires it to be in `owns` or
`edits`), and another that the Earth-like plan runs the engine's systems in the
order the engine always ran them, with the golden journal for the rest.

**What a rule says of order is what its systems read of one another's state.** A
constraint that names a rule the world does not have changes nothing, so an
order that holds in the whole set only because a chain of other rules gives it
is lost when one of them is left out. The Earth-like rules stated only part of
what they read, and 20 of the 88 sets of them that the check accepts made a
different world from the old order of the rules that remained (smoke before the
fire whose smoke it reads, heat before the weather whose air it reads, the
physics after the bodies). Each system now says what it reads: heat the air, the
light, the hearths' burn and the river's reaches; smoke the hearths' burn and the
wind; the river and the fire the scheduled changes that set a spring's flow and
a hearth's fuel; and the physics all run before the bodies move. A test runs every
set the check accepts, in the order the plan gives and in the old order of the
systems that remain, over a morning with a lit hearth and the hour a source
fails, and requires the same world where the orders differ
(`test/avwe/rules_composition_test.exs`). Two more tests in the same file state the
data flows once, as pairs that every accepted set must run in order, and ask that
the order the rules declare (`Ruleset.declared_order/1`, before the ids fill what is
open) puts one before the other for every capability that a rule requires or uses
and another provides, so that a dependency left unordered is not saved by the
alphabet. The check cannot see a dependency the manifest leaves out, so a rule
from outside the package is tested the same way by whoever writes it.

**The `ruleset` section of a definition** (`Avwe.Definition.Schema`, `Check`):
`{"preset": "earthlike", "with": [...], "without": [...]}` or `{"rules": [...]}`,
not both; with none the world runs the default preset. Reading checks it with
the other references and gives every problem with the path `ruleset`, and a
`rules` entry (the parameters of a rule) for a rule the world does not run is an
error, as is a rule named in `with`, `without` or `rules` that no package ships, `sim`
left out, and a rule both added and left out. What a definition contains has to be
served by its rules: bodies need one that provides `:bodies`, and guests one that
provides `:intents` (`Avwe.Definition.unserved/2`; without `play` they would be
told nothing). `Avwe.start_world/2` plans the ruleset, checks it against the
definition it is for (a struct as well as a file) and gives `{:invalid_ruleset,
problems}` for a bad one (`Definition.explain/1` writes the list); `:systems`,
when given, replaces the plan, for the tests that run one system. The hash covers
an explicit `ruleset`; a definition that names none runs the default preset of the
build that starts it, and if that preset's systems are not the saved world's the
world is snapshotted at once, as for any change of systems.
`Avwe.default_systems/0` is the default ruleset's systems.

**Inputs and hooks** (`Avwe.Input`, `Avwe.Hooks`). `Input` is a protocol on the
input's struct (`handle/3`, `order_key/1`, `validate/2`, `derived?/1`, `seq/1`,
`put_seq/2`; 4.4). `Region.submit/2` numbers an input and queues it, and a step
applies the inbox sorted by `{order_key, seq}`; `RegionServer.submit/3` asks
`validate/2` before it journals, so a refusal is never in the log; the journal
and the snapshot hold inputs as opaque terms with the `seq` the region gave
them, and a snapshot keeps those that are `derived?` (autopilot's). `Avwe.Intent`
implements it: `Actions` handles it, its body orders it, `Guests` validates an
arrival, and autopilot's are derived. An input a system made is not something to
send in, and `RegionServer.submit/3` refuses one that says it is `derived?`
(`{:error, :derived_input}`), since a journaled one would be numbered twice when
the region is rebuilt. A world is started with `:hooks` (default
`Avwe.Hooks.Play` and `Avwe.Hooks.Settings`), and the server asks each for what
it defines: `on_resume/2`, the inputs to accept and journal when a region has
been started again (play's releases the bodies whose holder has no live lease in
this world), and `on_reconfigure/3`, told when the saved region and the one given
may differ (the settings of a world from Quire that are ignored). The fifth place
4.4 counted, those warnings, did not go away with the definition's hash as 4.4
expected: the Quire path stays for tests, so they are a hook. Sim runs a test
input of its own (`Avwe.Test.Poke` with `PokeHooks`), so the hooks are tested
without play.

**`Region.near(region, location, radius_m, components \\ [])`** gives the ids of
the entities within `radius_m` metres of a position that have a `position` and
every one of `components`, sorted; who is near is the region's question, and
Discovery, which scanned every place for its own cell radius, asks it (30 m, its
three cells).

**The calendar** (`Avwe.Calendar`) is a value, `%Calendar{hours_per_day,
days_per_year, epoch}`, with the Earth's as `earth/0` and a form of each function
that takes a calendar (`day/1`, `year/1`, `at/3`, `describe/2`, `time_of_day/2`,
`format/2`); the forms that take none are the Earth's, so no call site moved. A
region keeps one (`Region.new(calendar:)`) and hands it to its systems in the tick.
The golden journal's state digests leave it out of the state, as they leave out
the systems. A world definition has no `calendar` key yet, nor are there named
moments or month and season names: the first world with another calendar (the
station, E8) decides their shape.

**The boundary** (`test/avwe/kernel_test.exs`, `Avwe.Test.Boundary`). The
kernel's files (`region`, `tick`, `rng`, `event`, `system`, `system_table`,
`calendar`, `space`, `store`, `region_server`, `world`, `clock`, `input`, `hooks`,
`rule`, `rule_package`, `ruleset`, `rules/sim`, `systems/miracles`) refer to no
module outside the kernel (read from each file's code with its aliases resolved,
so a name in a type or a spec counts) and use none of the words the test lists
(`body`, `percept`, `intent`; `earthlike`, `hearth`, `river`, `smoke`, `silt`, `kiln`,
`weather`, `spring`, `wind`, `heat`, `fire`), in code or in documentation. Getting there
made the region's terrain an opaque slot, the ruleset's packages and default
preset configuration, `Region` stop calling `Actions`, and `Store` and
`RegionServer` stop naming `Intent` and `Guests`. The test's list is what E2b
moved.

**Saving.** The snapshot is `{:avwe_snapshot, 3, ...}` (it was 2), whose region
lists system ids; the journal's records keep their version, since an input was
always an opaque term with its `seq` to the journal. As the spec said, a saved
dev world from before E2 is refused in the usual words.

**Differences from the plan above.** `Avwe.Rule` has no `parameters/0`, `seed/2`
or `invariants/0` yet (the schema and `Worldgen` still know what the three
Earth-like rules are told, and the conformance suite of section 6 is later), and
nothing hands out `facets/0` (there is no layer to register for one until `play`
is a project). The "names" check covers rules and system ids; verbs, behaviours
and modalities are E3 and after. `Calendar` is a value and not a behaviour. Two
rules may provide one capability. `Rule.version/0` is declared and not yet
recorded, so a change to what a system does under an unchanged id is not noticed
by a resume (a change to a module's code never was; what 4.3 calls "snapshotted
at once" is done for a change of the systems list or of their options). The
definition (`Definition`, its schema and its check, `Export`) stays in this
project, since its schema names Earth-like things; it moves apart when the rules
carry their own parameters (E7).

### E2b as built (the `avwe_sim` project)

**The project.** `avwe_sim` is a Mix project and a git repository of its own
(github.com/azmaveth/avwe_sim), cloned beside this one, with its own `mix.exs`,
lockfile, configuration, tests and CI. Its OTP application is `:avwe_sim`; the
modules keep the names they had (`Avwe.Region`, `Avwe.Store`, ...), so nothing
that calls them changed. It holds the nineteen files the kernel test of E2a listed
and an application, `Avwe.Sim.Application`, which starts the registries
`Avwe.Registry` and `Avwe.PubSub` and the `Avwe.Worlds` supervisor and registers
the systems of the rules the packages ship. It depends on nothing but Erlang/OTP
and Elixir (StreamData, Credo, Dialyxir and Sobelow are for developing it), so the
compiler holds it to naming nothing of ours, and its own test holds it to the words
(`test/avwe/kernel_test.exs`). Its CI is ours without the web client: lint, test,
Dialyzer, Sobelow, and the audit weekly.

**How this project uses it.** By path: `{:avwe_sim, path: System.get_env("AVWE_SIM_PATH")
|| "../avwe_sim"}`. A dependency is compiled for `:prod`, so none of the kernel's test
support is in our builds; a worktree of this repository somewhere else sets the
variable. The kernel reads its configuration from `config :avwe_sim` (the rule
packages and the default preset, set in our `config/config.exs`), and our
application no longer starts the registries. CI here checks the kernel out beside the
code (`.github/actions/kernel`): the branch of the same name as the pull request's if
the kernel's repository has one, otherwise master. So **a change that spans both
projects is two pull requests, the kernel's first.**

**What moved with it, and what did not.** The tests that need nothing of ours moved:
the calendar, the space, the tick, the system ids and the inputs as they were; the
region (a lamp where there was the Earth-like daylight), the id table (a package of
rules made for the test), the ruleset (its generic checks, and what a definition may
say of its rules, with a package of station rules), the store (31 tests, ported to
test inputs and a small region), and the hooks and system ids of a saved world, now
through a world the test starts (`Avwe.Test.Worlds`); new are a running world's
(stepping, subscribers, a live clock, listing). They run in a third of a second.
This project keeps what needs the Earth-like rules, the agent layer or a real world:
the Earth-like ruleset (`test/avwe/earthlike_ruleset_test.exs`), the rules' own tests
(including that every shipped system declares an id of its rule's), the store with
real intents and the Ember Reach (`store_test.exs`), persistence, the end-to-end
system ids through `start_world`, and the golden journal, which now runs against the
dependency and is unchanged. Nothing was deleted without a test of the same thing in
its new home.

**What changed in the code that moved.** `Avwe.Input` has a fallback: a term that
does not implement it is refused when it is submitted (`{:error, {:not_an_input,
term}}`) where it used to crash the region's server, and Elixir 1.19 insists on an
implementation before the kernel compiles alone. The ruleset reads `:avwe_sim`. The
pointers in its documentation to this repository's documents say so. Nothing else.

**Not yet.** The plan's `avwe_play` (E3 and after); the kernel's own words test only
covers the words the E2a test listed.

## 9. Tests

CLAUDE.md applies: an end-to-end test through the real transport for every
feature, deliberate breaks of each piece, replay exact.

- **The golden journal** (E1): a recorded run with a fixed seed. After every
  slice, replay it under the new code and compare the whole event stream and
  the final state (system ids normalised). It is what makes "no behaviour
  change" a fact, and its failures are read as bugs, not re-recorded. It lives
  with the Ember Reach.
- **Old against new** (E1): build the Ember Reach both ways and compare.
- **The boundary** (E2 on): the compiler for module references, and the words
  tests in the engine projects.
- **Composition** (E2): every refusal of 4.2, each with its message.
- **Inputs** (E2): sim runs a test input handler of its own, so the hooks are
  tested without play; play's handler is tested against the same hooks.
- **Conformance** (section 6) for each rule and each preset.
- **Loader**: every refusal, in plain words and all at once; no atoms from the
  file; a definition with an unknown rule, version, verb or component.
- **The station** (E8): the same e2e shapes as the Reach, through telnet and
  MCP and the web page's text view, and the reference agent.
- **Performance**: the step bound with the tables in place (they are built
  once, not per step).
- **Deliberate breaks** of each piece, one at a time, each caught.

## 10. House rules

The simulation core still does no I/O, systems still draw only from
`Tick.rng/2`, intents are journaled as they are accepted, autopilot's intents
are derived state, and words are plain text (CLAUDE.md, unchanged). New:

- **No engine names a rule, and sim names no body.** The compiler holds the
  first; the words tests cover the rest.
- **Definitions are data.** No module, function or atom comes from a
  definition file; a string maps to one through a table a rule declares.
- **Identity is by id.** Systems, verbs, perceivers and behaviours are saved
  and journaled by stable id or atom, never by module name.
- **A rule writes only what it owns.** Anything else it feeds through its own
  entities or events.
- **Rules reach state through `Region`'s functions**, not by matching the
  struct's layout (`get`, `put_component`, `with_components`, `near`, the
  `fields` and `env` accessors). What a field or an env value holds is opaque
  to sim and owned by one rule.
- **Projections are pure, read-only and body-centred.** A client changes the
  world only through its body's inputs.
- **The hash covers the definition.** A world is its engines, its rules (id and
  version) and its definition (hash), and replay checks all three.

## 11. Long-term shape

The aim beyond this spec (Hysun, 2026-10-08): an engine that could one day power
a 3D, real-time, MMO-scale world, represent as much of the real world as a
model needs, and show it to each client at the detail that client can use: an AI
agent through intents and percepts, a person through a 3D client or a MUD-style
prompt, in the same world. None of that is built or planned here. This section
records the doors kept open, so that nothing in E1 to E8 closes them.

Three problems hide in that sentence, and they land in different layers:

| Problem | Lands in | What it needs eventually | Door kept open now |
|---|---|---|---|
| **Fidelity** ("anything in the real world") | Rules | Many models, at different levels of detail, near and far | Rules are plain modules; truth never depends on who is watching (DESIGN 6.8) |
| **Projection** ("squash down per client") | The view, inside play | Prose, glyphs, 3D state streams and agent percepts, all from one truth | Projections are pure, body-centred and derived; `repr` layers are data on entities (name, description, glyph, sprite, model; DESIGN 8.4) |
| **Scale and real time** (MMO) | Sim, a gateway, the platform | 20 to 60 Hz steps, thousands of entities, zones across nodes, a database | Opaque locations, `Region.near/4`, system periods, global entity ids, state reached through `Region`'s functions |

**What already carries.** A client uses the richest representation layer it
supports; scenes are derived from the same view as percepts and never stored;
observation never changes outcomes; systems use the step length; nothing reaches
world state but a controller's intents. A 3D client, a MUD client and an LLM
agent are three projections of one body's perception: the server decides what
the body may know, and the client decides how to show it. A person in a 3D client
and Claude in a text session can be bodies in the same world, each seen by the
other as an avatar or as "a figure approaches".

**Agents and embodiment.** An LLM thinks in seconds, so the closest thing to a
fully embodied agent is not raw tick-rate access but hierarchical control: the
agent deliberates in plans (durative intents), and the body's own motor and
reflex layers execute them every step, as `go`, `Movement` and the autopilot do
now. A person's 3D client supplies that layer by hand, through continuous
control.

**The doors, and where each stands.**

1. *Opaque locations and neighbour queries.* A location means whatever the space
   says; ranges are in metres; `Region.near/4` replaces scans; `raycast/2` is
   optional. In this spec (4.9).
2. *Generic inputs.* Discrete intents with results now; continuous control,
   which is state and not an intent per frame, can be a second handler. In this
   spec (4.4).
3. *Periods and native systems.* A system may declare its period; a hot system
   may later be native. In this spec (4.3).
4. *A replaceable state backend.* Rules reach state through `Region`'s functions;
   fields are opaque terms that may later carry their own encode and hash so a
   native-backed field can join snapshots and the state hash. A house rule now
   (10).
5. *Truth independent of observers, and global ids.* Entity ids are global and
   stable; a region is the unit of distribution; level of detail, if it comes,
   is a function of state, never of a client's camera. Already so.

**Not now.** 3D space; rigid-body physics; a replication gateway and state
streaming; zones across nodes and entity handoff at borders; a database for
accounts and inventories; simulation level of detail; native systems; a `view`
project; asset facets on rules (models, animations, audio). Each is a
replacement of a component behind an interface above, not of the architecture.
The `view` becomes its own project when a second family of projections (3D
replication) exists, and rules gain a third facet for assets the same way.

**Costs, honestly.** Exact replay stays achievable per region, but with native
physics it needs one numeric backend per deployment (DESIGN 6.4), and across
regions it would need deterministic message ordering. The principle stays; it may
be relaxed at a zone border if it ever costs too much. And the state model
(immutable terms copied each step) is the right one for dozens of bodies and a
valley, and the wrong one for thousands of entities at 60 Hz; the doors above are
what make that a swap and not a rewrite.

## 12. Out of scope

- Three-dimensional, orbital or continuous space (decision 3), a hybrid of
  grid and graph, and a scene for a place graph (decision 9: with 3D).
- Everything under "Not now" in section 11.
- Units other than a 60-second minute and a 60-minute hour (decision 8).
- The pipeline that has an LLM draft a rule and its tests; decision 2 says
  only that it goes through review.
- The Quire compile and proposals are specified in `docs/quire-spec.md`, not
  here; tiers of non-player brains are a spec of their own.
- Needs, satisfiers and utility curves as data, and a data form for cultural
  norms, until a world asks for them.
- Languages other than English.
- More than one region per world in the new definition (the engine runs
  several regions today; the definition describes one until a world needs two).

## 13. Open questions

None outstanding; Hysun's answers and recommendations settled the earlier ones
(decisions 5 to 12 and the accepted defaults). Left to the slices that need them:

1. **The shape of the facet registration** (4.1). E2 settled the hooks (4.4,
   "E2a as built"); nothing hands out `facets/0` until `play` is a project, so
   its registration is settled with E3.
2. **What a capability call costs in the step.** E2 has no capability calls to
   measure, since the systems still call each other by name. What it did add to
   the step, finding every system through the id table, costs nothing visible:
   the Ember Reach's twelve systems take 2.1 ms a step against the 10 ms bound
   (about 2 ms before). A capability call is measured against the bound when E3
   to E5 route the six direct calls through them.
3. **When the adapters become projects.** The same argument applies to MCP,
   telnet and the web page; ArborMCP's arrival is the natural moment for MCP.
4. **When the `view` leaves play.** When a second family of projections exists.
