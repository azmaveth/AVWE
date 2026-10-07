# AVWE M2b: Many lenses

> Written 2026-10-06 from docs/DESIGN.md sections 8, 9 and 13, docs/m2-spec.md
> and the code as it stands after M2a (master at `69b6a95`). Where this spec
> and DESIGN.md differ, this spec wins and DESIGN.md is updated afterwards.
> Names of modules and fields are proposals; the behaviour is the contract.

**Decisions** (Hysun, 2026-10-06):

1. M2b is the spectator view, its three field overlays (heat, water, smoke)
   and a "watch" link in the lobby: DESIGN 13's done criterion, and nothing
   more.
2. Sprites and the remembered map are out of M2b. Sprites need art, and there
   is nothing to draw: Quire has none. A remembered map is body memory, which
   is simulation state (journal, snapshots, hash) and would serve telnet, MCP
   and Arbor as much as a page, so it belongs near M3. Both stay in "Later".
3. Defaults, taken: a watcher sees everything, as DESIGN 9 says of spectators,
   but not the game-master annotation of a miracle; all three overlays; no
   pause, speed or replay controls (those are game-master actions, and a
   spectator cannot act); the whole valley with zoom and pan; and a log of what
   the watcher is told, as the telnet watcher is.

**Done when** (DESIGN 13): a watcher in a browser sees the river's reaches
fall silent one after another, and the silt cool, as the telnet watcher is
told of them.

A *world scene* is what a spectator sees: the whole valley, everything in it,
and its fields drawn over it. Like the embodied scene it is derived, so the
journal, the snapshots and `Region.state_hash/1` are untouched, and it goes
through `Avwe.Session` as every controller does.

## 0. What the code already gives, and what it does not

- **A spectator exists, with no scene.** A session with no body is told of the
  world's events as the telnet watcher is: `Avwe.Perception.percepts/3` with a
  nil body, which says a river reach fell silent once for each place along the
  river and not once for each reach. It acts on nothing. But `Avwe.Scene` is
  body-centred (a window, a circle of sight), and a spectator's `scene/1` is
  `nil`. So the page's log is free: it is the session's percepts.
- **The ground exists once.** `Avwe.GroundCache` keeps the 64 KB map of each
  terrain, built in about a second the first time.
- **The fields are small.** Measured on the Ember Reach (256 by 256 cells, 23
  reaches), three world hours in:

  | | |
  |---|---|
  | the snapshot copied out of ETS | 0.45 ms (476 KB as a term) |
  | heat | 3 481 stored entries: 3 479 cells (the banks within 6.5 cells of the channel, the clay patches, every hearth's cell) and two backgrounds, one for all open grass and one for all open stone |
  | every stored cell's temperature | 78 µs |
  | the heat rows of the whole map, run-length coded | 8 KB, 3 ms (a first, naive version) |
  | the river | 23 reaches, each `%{silent, temp_c, volume}`, with a channel span and a midpoint in the terrain |
  | the river's bed cells | 694, 28 to 33 to a reach, each mapped to its reach in 1.7 ms in all |
  | smoke | a list of puffs `{x, y, g}`, none at that hour |

  So an overlay is a few kilobytes and none needs a 65 536-cell grid a step.
- **The per-step event view has no fields.** `Region.view/1` leaves them out;
  the published snapshot (`RegionServer.snapshot/2`) has them and the terrain.
  A spectator session reads the snapshot, which costs about half a millisecond
  a step.
- **Nothing in the simulation needs to change.** Everything an overlay draws
  is already stored; a scene only reads it.

## 1. Slices

| Slice | Scope |
|---|---|
| **M2b-1** | The core: `Avwe.WorldGround`, `Avwe.WorldScene` and its overlays, spectator scenes in `Avwe.Session` |
| **M2b-2** | The page: "watch" in the lobby, `AvweWeb.WatchLive`, the hook that draws the valley and its overlays, zoom and pan, the log and the clock |
| **M2b-3** | The proof: the page in a real browser, and the done-criterion test, a browser watcher and a telnet watcher through the river's drying |
| Later | Sprites; a remembered map; replay and time controls; keyboard play; Phoenix Channels for Arbor (M3) |

Not in M2b: sprites, a remembered map, accounts, pause or speed or replay,
the miracle's annotation, mobile layouts, and any change to the simulation.

M2b-1 is merged (GitHub #7, `c43bc85`). M2b-2 is built, and section 3 says how.

## 2. The core

**World ground** (`Avwe.WorldGround`, pure; static). The map's ground, which
never changes for a terrain, so it is built once and kept with the ground map
(`Avwe.GroundCache`), and a client is given it once:

- `width` and `height`;
- `rows`: every row, run-length coded as the embodied scene's are
  (`"g3s2c1"`), with the same letters, except that the channel bed is always
  `b`. Whether the river runs in a bed cell is the water overlay's to say, so
  the ground never has to be sent again when a reach falls silent;
- `reaches`: for each reach, the cells of its bed, so a client can draw them
  wet or dry from the water overlay alone.

**World scene** (`Avwe.WorldScene`, pure; the dynamic part):

- `time`, and `light` from 0.0 to 1.0 to the nearest tenth (the world's
  `env.light`), which a client uses to dim the valley at night;
- `things`: every body, hearth and place in the world, with no limit of sight.
  Each is `%{id, kind, cell, name, glyph}`, and a body adds `holder`, who holds
  it (`nil` when its routine does). As in the embodied scene, a thing is built
  from the world's components and its glyph from `Avwe.Repr`;
- `overlays`, each a derived layer that a client may draw or hide:
  - `water`: one entry for each reach, `%{silent, temp_c, steaming}`;
  - `heat`: the ground's temperature in whole degrees, as rows over the whole
    map in the same run-length code, one letter for a level (level 0 is
    -10 °C, level 51 is 41 °C, beyond clamped) and `.` for a cell that is not
    stored, which has its ground's background. With `base`, `step`, and the
    two `backgrounds` in degrees, so a client needs no table;
  - `smoke`: the puffs as `[x, y, grams]`, the position to a tenth of a cell
    and the mass to two figures;
- `legend`: the layers of the kinds in use (`Avwe.Repr`). The overlays' are
  `Avwe.Repr.overlay/1` (name, description, unit and a colour ramp, or the
  colours of a river's states, or one colour for puffs), and `to_map/1` puts
  each beside its data, so the colours belong to the server and the hook only
  draws what it is told.

`same_view?/2` ignores `time`, as the embodied scene's does. `to_map/1` gives
plain data with string keys, as it does.

Everything is built from the snapshot and the terrain by plain functions, in
sorted order, with no clock and no randomness.

**Session.** A session opened with `scenes: true` and no body is a spectator
with scenes: `scene/1` gives its `WorldScene`, and from then on it sends its
sink `{:avwe_scene, session, scene}` after a step that changed it, as an
embodied session does. It reads the snapshot for the fields on each step, and
pushes only when that is the snapshot of the step the percepts are of: one
already ahead is left to the next message, which comes with its own percepts, so
a scene is never ahead of the words about it, and a burst of steps reaches the
page as its newest. Its sink may also ask for the world ground (`ground/1`),
since that is sent once and not with every scene; the call returns when the
ground is built, which takes about a second the first time for a terrain, and
the session goes on meanwhile. A spectator without `scenes: true` (telnet's,
MCP's) and every embodied session behave as they always have.

## 3. The page

- **Lobby.** Each world has a "Watch" link, to `/watch/:world`. Nobody holds
  anything, so any number of pages may watch, and the question of who a page
  is does not arise.
- **`AvweWeb.WatchLive`.** A spectator session with scenes, the page's process
  its sink. The page is the valley fitted to the width of the screen, with zoom
  steps (up to eight cells' worth of pixels each) and a drag to pan; three
  toggles for the overlays (`aria-pressed`); the world's clock; a legend; and
  the log of what the watcher is told, as lines, as the play page's. Clicking
  a thing names it and says who holds it. There is no command line.
- **One hook** draws the valley. The ground goes to the page once, in an
  attribute of its own; the scene goes in another and replaces itself, so
  LiveView sends only what changed. The hook keeps the zoom and the pan across
  scenes, and writes what it drew into `data-drawn-*`, as the embodied hook
  does, so that tests read state and not pixels.
- **Drawing.** Ground in its legend colours; the heat overlay as a translucent
  colour of each stored cell by its ramp (a background cell is its ground's
  background); the water overlay colouring the bed cells of each reach, wet or
  dry, with a pale halo on the banks of a steaming reach; smoke as translucent
  discs by the square root of the grams; things as glyphs on top; and `light`
  dimming the whole.
- **Security.** The policy is unchanged. The page shows everything, by design:
  it belongs on loopback, where the endpoint is, and DESIGN 9 says so of
  spectators.

**As built (M2b-2).** What differs from, or is settled beyond, the above:

- **The ground has a legend.** `Avwe.WorldGround` carries the grounds its rows
  use, each with its glyph and colour from `Avwe.Repr`, so the page holds no
  table of them, and the page's own legend is those and the things'.
- **Defaults.** The river and the smoke are on to begin with, the heat is off:
  it covers the ground it explains. The buttons are the page's own
  (`aria-pressed`, flipped by `JS.toggle_attribute`, and the hook told by a
  `map:overlay` event), so the server never hears which are on. The key to the
  heat is an SVG gradient (the policy forbids inline styles) and is hidden by
  CSS while the Heat button is not pressed.
- **Zoom and pan.** Zoom is ×1, ×2, ×4 and ×8 of the size that fits the whole
  valley to the width; the buttons, the wheel (around the cursor, one step each
  150 ms) and "Whole valley" set it, and a drag pans, with four pixels before a
  press is a drag and not a click. The pan cannot leave the map.
- **Drawing.** In this order: the ground, dimmed by the light (only the ground:
  the overlays are drawn at full strength, so the heat can be read at night);
  the heat, at 80% opacity; the river's bed, running or silent, with a haze on
  the banks of a reach that steams; the smoke as discs of radius
  `min(6, 1 + 4√g)` cells; the things, as markers while a cell is under ten
  pixels and as glyphs from ten, a ring on a body somebody holds. A cell that
  the heat does not store is coloured as its ground's background temperature,
  grass's or stone's.
- **A click** sends `"cell"` with `{x, y, r}`: the cell, and how many cells a
  click may miss by, about eight pixels' worth at this zoom, so none at a big
  cell (the server keeps `r` to 0 to 4 and ignores anything that is not three
  integers). The server finds the nearest cell with
  anything on it, within `r`, and tells everything there, a body first, then a
  hearth that burns, a hearth, a place: "Mira Vale (person), on its routine;
  the kiln-house hearth (cold hearth); Ember Reach (place)." A body somebody
  holds says by whom, and a click on nothing says "Nothing there."
- **Joining.** A plain request is the page, "Joining...", and starts no session;
  its socket opens the spectator, takes the scene at once and asks for the
  ground beside it (the first page for a terrain waits about a second for it,
  and sees "Drawing the valley..." meanwhile). A world that is not running sends
  the visitor to the lobby with a notice; one that stops while it is watched
  leaves the page standing with a notice and a way back. A world with no
  terrain says it has no map to draw, and still has its log.
- **The log** is the session's percepts as lines, the last two hundred (a
  stream), in the order the telnet watcher is told them.
- **Tests.** `Avwe.Test.WebPage` is a page's side of the LiveView protocol over
  a real socket (the plain request, the join, an event, the frames that follow),
  shared by `test/e2e/web_test.exs` and `test/e2e/web_watch_test.exs`;
  `test/avwe_web/watch_live_test.exs` is the page through `Avwe.Test.WebCase`;
  the hook's arithmetic is `world.js`, with its Node tests on fixtures that the
  server writes (`AVWE_UPDATE_FIXTURES=1`).

## 4. Tests

CLAUDE.md applies: every user-facing feature has an end-to-end test through
its real transport, and a deliberate-break check.

- **Pure**: world ground (rows decode to the ground map; the bed is `b`; every
  bed cell is in exactly one reach); world scene (things from the components,
  holder, the overlays: a reach that is silent is silent; heat levels
  monotonic in temperature and clamped; background cells absent; smoke
  quantised; the legend; `same_view?/2`; `to_map/1` as JSON), and properties
  (a row's code decodes to its cells; the same snapshot gives the same scene).
- **Session**: a spectator with scenes is given the whole valley and its
  overlays, is sent a scene when a reach falls silent and none when nothing
  changed, and frees nothing (it holds no lease); telnet's and MCP's
  spectators are as before.
- **The page**, through `Avwe.Test.WebCase`, then over a real socket
  (`test/e2e`): the lobby offers the watch link; the page draws what the scene
  says (the hook's `data-drawn-*`); a reach falling silent changes the water
  overlay and puts the telnet watcher's line in the log; the toggles; zoom and
  pan; a click on a thing. The drawing arithmetic has Node tests on scenes the
  server builds, as before.
- **Browser** (`test/browser`, Chromium): the page loads under the policy,
  draws the valley, toggles an overlay, zooms.
- **The done criterion**: the Ember Reach started an hour before the source
  fails (812 AR, day 200, hour 15), a browser watcher and a telnet watcher, and
  the world stepped through the drying: the page's water overlay turns reach
  by reach from the source down, the telnet watcher is told of each place as
  the page's log is, and the heat overlay's bank cells cool.
- **Deliberate breaks** of each piece, one at a time, each caught.

## 5. Rules

The rules of the core apply: pure functions, no I/O in the simulation, sorted
iteration, `Avwe.Tick`'s clock and nothing else. A thing's name is canon, never
a player's text, and what a watcher reads in the log is escaped by the
templates as the play page's is. The world ground and the scene are derived
data: nothing here is snapshotted, journaled or hashed.

## 6. Delivery

Three changes, each ending with its tests and its docs, in this order:

1. **M2b-1**: this spec; `Avwe.WorldGround`, `Avwe.Repr.overlay/1`,
   `Avwe.WorldScene`; spectator scenes in the session; the DESIGN.md updates
   (13, and 8.4's account of scenes).
2. **M2b-2**: the lobby's link, `AvweWeb.WatchLive`, the hook and its Node
   tests, the page's tests.
3. **M2b-3**: the browser tests and the done-criterion test.

## 7. Open questions

1. **Is a whole degree enough?** (Settled in M2b-1, by looking at the Ember
   Reach.) Yes. The open ground swings 24 degrees between noon and dawn, and the
   silt banks (2 057 cells) swing about 6, so the banks are warmer than the open
   ground at night and cooler by day. Sixteen hours after the source fails they
   are about three degrees cooler than if it had run on: three levels, drawn.
   `base` and `step` are in the scene, so a finer step is a change to one number.
2. **A world that outruns the page.** At one step a second a scene a step is
   easy. History mode (M4) steps by the hour; a session may then need to send
   at most a few scenes a second, and the newest.
3. **Many watchers.** Each spectator session derives its own scene from the
   snapshot, which is fine for a few. If there are many, derive it once a step
   and fan it out.
