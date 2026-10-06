# AVWE M2: A window onto the world

> Written 2026-10-06 from docs/DESIGN.md sections 8, 9 and 13 and from the
> code as it stands after M1 (master at `8c03d64`). Where this spec and
> DESIGN.md differ, this spec wins and DESIGN.md is updated afterwards.
> Names of modules and fields are proposals; the behaviour is the contract.

**Decisions** (Hysun, 2026-10-06):

1. The web client is Phoenix and LiveView.
2. The embodied view comes first. The spectator view and its field overlays
   (heat, water, smoke) are M2b, after this.
3. Rendering is glyph-only first: characters and colour on a canvas.
   Sprites come later, through the same representation layers.
4. Browser testing is both: Node unit tests for the drawing arithmetic, and a
   headless-browser end-to-end test of the play page in CI (section 4).
5. No remembered map in M2a: the canvas shows what is in sight now, and a
   reload forgets.

**Done when** (DESIGN 13): a telnet player, a web player and Claude are in
the world at once and each perceives the others.

M2 adds a *scene*: what a body can see, as something a graphical client can
draw. It adds a representation layer so a client can ask for the richest
form it understands, a web client built on both, and the groundwork that
keeps that client from becoming a second copy of the telnet one. Everything
goes through `Avwe.Session`; the web client has no way into world state that
telnet and MCP do not have.

## 0. What the code already gives, and what it does not

- **Percepts and prose exist.** `Avwe.Perception.look/2` says what a body
  senses; `Avwe.Prose` turns it into sentences. A web page can show these
  as they are.
- **Nothing is spatial yet.** A look says "Pell, 70 m to the east", never
  where Pell is. Terrain is a description (a channel line, rises, clay),
  with `Terrain.ground/2` computing any cell on demand.
- **That is slow to draw from.** Measured on the Ember Reach: `ground/2`
  costs about 16 µs a cell. A noon-sized window of 101 by 101 cells is
  163 ms, far too much to redo every step; the whole 256 by 256 map is
  about a second, once. Terrain never changes, so the answer is to compute
  it once and cache it (2.3).
- **Command handling is trapped in telnet.** `Avwe.Telnet.Command.parse/1`
  is pure, but turning a parsed command into an act (resolving a place or
  hearth name against the look, refusing a spectator) lives inside the
  `Avwe.Telnet.Connection` process. A web client would be the second copy,
  so it is extracted first (2.1).
- **`repr` is only a name and a description.** DESIGN 8.4 promises glyph,
  sprite and model layers; none exists.

## 1. Slices

| Slice | Scope |
|---|---|
| **M2a** (this spec) | Scene, representation layers (glyph), the embodied web view, the lobby, a command line and clickable affordances |
| **M2b** | The spectator view and its overlays (heat, water, smoke); "watch" in the lobby |
| Later | Sprites; a remembered map that outlives a page load; keyboard play; Phoenix Channels for Arbor (M3) |

Not in M2a: accounts or any login (the server binds to loopback), mobile
layouts, sound, a map editor, and any change to the simulation. Nothing in
M2 adds state: a scene is derived, so the journal, the snapshots and
`Region.state_hash/1` are untouched.

## 2. Core changes (pure, except where marked)

### 2.1 One command layer (built)

The part of `Avwe.Telnet.Connection` that turned a parsed command and the
current look into an act now lives with the parser, in `Avwe.Command` (which
moved from `Avwe.Telnet.Command`, as nothing in it is telnet's). It gained
two pure functions:

    Avwe.Command.needs_look?(command) :: boolean()
    Avwe.Command.interpret(command, look) ::
      {:act, verb, opts} | :look | :time | :help | :quit | :noop | {:error, String.t()}

`{:act, ...}` is what to hand to `Session.act/3`, with a place or hearth
already resolved (`go the dry bend`, `kindle the lodge hearth`).
`:look`, `:time`, `:help` and `:quit` are answers each client gives in its own
way (the telnet help text is not the web page's), and `:time` and `:help` are
the player's presence, so the client touches the session for them. `:noop` is
an empty line. `{:error, ...}` is the refusal in the words telnet has always
used ("Which do you mean: ...", "You don't know a place called ...", "You're
only watching."). The look is read only for `go` and for a named hearth;
`needs_look?/1` says when, so a client fetches one only then. Telnet's
`run/2` is now a switch over the outcome, and its end-to-end tests, which are
the safety net, were not edited.

### 2.2 Representation layers (built)

`Avwe.Repr` (pure) answers "what is this kind of thing, at each layer":

    %{name: "silt", description: "...", glyph: %{char: ".", color: "#b8a070"}}

for the seven ground kinds (`:channel_bed :reeds :clay :silt :stone :grass`,
and `:water` for a channel cell where the river runs; the bed is dry
otherwise) and for the kinds of thing a scene can show: `:body`, `:hearth`
(cold), `:hearth_burning`, `:place`, and the two ways a fire shows from far
off, `:smoke` and `:glow`. A layer a kind lacks is absent, not empty: a sprite
layer will be `sprite: "terrain/silt"`, added to the same maps later, and a
client uses the richest layer it knows (DESIGN 8.4). Each kind has its own
character as well as its own color, so the map reads without color.

A body, being one of many, has its own glyph: the one its world gave it, else
an `@` in a color taken from its id, so the same body is the same color every
time and two bodies in sight are usually told apart (`body_glyph/2`).

A character's glyph can be set in the world's configuration (`glyph:` and
`color:` beside `routine:`; either alone is enough). They are validated when
the world is built, as the rest of the config is: a glyph is one printable
character, a color is `#rrggbb`, or the build raises `ArgumentError`. The
override is stored in the body's `repr`. Only characters can be overridden in
M2a: places come from Quire pins and carry only a label, and a hearth's glyph
follows whether it burns. Quire has no glyph fields; glyphs in articles are a
Quire matter and not part of M2.

### 2.3 The ground map (built)

`Terrain.ground_map/1` (pure) returns every cell's ground kind as an
`Avwe.GroundMap`: one binary, a byte a cell, row by row, with `at/2` and
`slice/4` to read it. It is derived data: not part of the region, not
snapshotted, not hashed, and the same terrain always gives the same map. It
agrees with `ground/2` on every cell (tested on the Ember Reach and on a small
land with every kind of ground).

Building it is about a second for the 256 by 256 Ember Reach, so it is built
once. `Avwe.GroundCache` (runtime) keeps each in `:persistent_term`, keyed by
the terrain's content, so every session and world with the same terrain shares
one (about 64 KB), and concurrent first requests take a lock instead of each
doing the work. It is lazy: nothing is built at world start (the tests start
hundreds of worlds), only when a session first asks for a scene (2.5), which
adds the map to the view it works on, as it already adds `:terrain`. A world
with no terrain has none, and its scenes have no ground.

### 2.4 The scene (built)

`Avwe.Scene.build(view, body)` (pure) is what the body can see now, built from
the view a session works on (the region's view, its `:terrain`, and the
`:ground` map):

| Field | Meaning |
|---|---|
| `you`, `holder` | the viewer (`id`, `name`, `glyph`), and who holds its body: a controller, or `nil` for its routine |
| `center` | the viewer's cell |
| `radius` | sight in cells, `Perception.sight_cells/1`: 5 at night, 50 at noon, taken up to the next half cell so it does not change every minute at dusk; `light` is to the nearest tenth, for the same reason |
| `origin`, `size` | the square window of cells that holds the circle of sight and everything shown |
| `rows` | the ground of each cell of the window, as run-length-coded rows (below), or `nil` in a world with no terrain; cells outside the circle are blank, because the server sends what is seen and nothing more |
| `things` | what is in sight, each `%{id, kind, cell, name, glyph}`: bodies, hearths (cold or burning), the places the viewer knows, and fires seen from afar (`:smoke` by day, `:glow` by night) |
| `legend` | the layers (2.2) of the kinds used, and only those |
| `time` | the world's time; the one field that is not part of what makes a scene differ (`same_view?/2`) |

Where the river runs is in the rows, not a separate list: a bed cell whose
reach is running is `water` and otherwise `channel_bed`, so the same channel is
water in 812 and a dry bed in 813, and goes dry again, reach by reach
downstream, after the source fails.

**One rule of sight.** `things` is built from the look's own lists (`bodies`,
`hearths`, `fires`, `places`), each of which gained a `cell`, as did the
look's own (`look.cell`); the circle is the look's sight. The scene never
recomputes visibility, so the page and the prose cannot disagree, and a
property test holds it: bodies, hearths, fires and in-sight places are the same
in both. A known place beyond sight is not drawn on the map; it stays in the
HUD list as a button, as telnet lists it.

**The window grows for fires.** The look shows a fire by its smoke or glow from
at least 200 m, farther than a body sees at night (50 m), so the window is
sized to hold every thing as well as the circle, and the ground in the extra
space is blank. (The draft of this spec missed that; a test found the rows
beyond the circle being drawn once the window grew.)

**Rows.** Each row is `size` cells, west to east, as runs of one letter and a
count: `"g3s2.4"` is three grass, two silt and four cells not seen. The letters
are `g` grass, `s` silt, `c` clay, `t` stone, `r` reeds, `b` bed, `w` water and
`.` for blank (`Scene.kind_at/2` decodes one). A noon window of 101 by 101 is
under four kilobytes this way. The scene is plain strings, numbers and lists,
so a client in any language can read it. This is Mira at night in the town
(813, 22:00), as the code builds it (the legend is the two kinds below and the
ground kinds in the rows):

    center: {121, 138}   radius: 5.0   light: 0.0   holder: :human
    origin: {116, 133}   size: 11
    rows:   [".5s1.5", ".2g3c1s3.2", ".1g2c5s1r1.1", ".1g1c7r1.1", ".1g1c7r1.1",
             "g1c8r1b1", ".1g1c7r1.1", ".1g1c7r1.1", ".1g2c5s1r1.1", ".2g3c1s3.2", ".5g1.5"]
    you:    %{id: "mira-vale", name: "Mira Vale", glyph: %{char: "@", color: "#e8a07a"}}
    things: [%{id: "town-hearth", kind: :hearth, cell: {121, 138}, name: "the kiln-house hearth",
               glyph: %{char: "o", color: "#8a8078"}},
             %{id: "ember-reach", kind: :place, cell: {121, 138}, name: "Ember Reach",
               glyph: %{char: "#", color: "#d8c8a8"}}]

(The eleven rows are the town's clay streets around her, and the dry bed's
reeds and silt at the east edge, as the circle of five cells clips them.)

A spectator has no scene (that is M2b), and neither has a body that is nowhere.
A world with no terrain has things and no rows. Cost: about 1 ms at noon and
0.1 ms at night, with the ground map built (the perf test bounds it at 10 ms).

### 2.5 Sessions produce scenes (built)

`Avwe.connect/2` takes `scenes: true`. `Session.scene/1` returns the current
scene, for the first draw, and from then on the session sends its sink
`{:avwe_scene, session, scene}` after a step that changed it (the body moved,
sight changed by half a cell or more, something in sight moved or changed, a
reach started or stopped running), and never when nothing did. Whoever holds the
body is part of a scene, so a yield or a retake is a change too. A session
without the option behaves exactly as before, so telnet and MCP are not
touched; a spectator has none (`scene/1` gives `nil`; M2b).

**A scene is built from the same view as the step's percepts**, in the
session's own process, and sent after them, so a client never draws a world
ahead of the words about it. The simulation does no extra work: the region
server sends the same 14 KiB view it always sent (the Ember Reach's; its fields
are not in it), and a step costs the same with a scene session connected (2.09
ms against 2.12 ms, measured).

**Every step, not every event.** The region server told a subscriber only of
steps that produced events. A body walks, and the light changes, between
events, and a client that waited for an event would see Odo's kilometre-and-a-half
walk as a few jumps and miss the dusk. So `Avwe.subscribe/2` takes `steps:
true` (default `false`), and the session asks for it when it has scenes. Every
other subscriber is woken exactly as before, and a test counts the wake-ups
(only the scene session hears a quiet step).

**Order and staleness.** A client's first scene is the one it asks for.
Nothing is sent before that, because a scene already on its way could be
older than the answer and overwrite it, and the quiet body that never changes
again would stay wrong. After that the session sends a scene when it differs
(`Scene.same_view?/2`, which ignores the time) from the last the client was
given, pushed or asked for. A client that asks again while scenes wait in its
mailbox keeps the one with the later `time`. The session never waits on its
sink, so a client that falls behind draws only the newest scene it has.

**The ground is built in the background.** The ground map is cached per
terrain (`Avwe.GroundCache`) and takes about a second for the Ember Reach the
first time. A session finds it cached or starts the build in a task and goes
on: its scenes show what is in sight and no ground (`rows` is `nil`, as in a
world with no terrain) until the map arrives, and the first scene with the
ground follows at once. Connecting is never held up, and a larger map would not
change that. (Warming the cache when a world starts, so that nobody sees the
bare scene, is a one-line addition for the application's own worlds, left for
the web layer.)

**Budget.** With the ground map built, a scene costs under 1 ms warm; the
perf test (`--include perf`) bounds it. A web session adds one scene per step
at most.

## 3. The web layer

### 3.1 Phoenix, minimally

Dependencies: `phoenix ~> 1.8`, `phoenix_live_view ~> 1.2`,
`phoenix_html ~> 4.3`, `esbuild` (dev, to bundle one JavaScript file) and, in
test, `phoenix_test` (which brings `lazy_html`) and `phoenix_test_playwright`
(open question 2). No Ecto, mailer, gettext or Tailwind: the app has no
database and the pages are simple, so styling is one plain stylesheet. The
modules are hand-written under `lib/avwe_web/` rather than generated, so
nothing is imported that is not used.

The HTTP adapter is Bandit, Phoenix's default, declared in `mix.exs` by
name rather than arriving through another dependency (open question 1,
settled).
Cowboy is here today only because ExMCP 1.5 needs it. ArborMCP 2
(`arbor_mcp`, `Arbor.MCP.*`, now a release candidate) makes its HTTP
backends optional and pins Bandit 1.12.5, Thousand Island 1.5.0 and, for
Cowboy, Ranch 1.8.1 (we run 2.3.0). A web on Cowboy would be pushed back a
Ranch major version when the MCP adapter moves to v2; a web on Bandit
already sits on the stack v2 and Phoenix both lean toward. Until the MCP
adapter moves (a separate task: four files in `lib/`), the app runs two HTTP
servers, one for each. Nothing in `AvweWeb` touches the adapter, so changing
it is a config line.

The endpoint listens on `127.0.0.1:4042` (telnet 4040, MCP 4041), allows only
its own origin, and takes its secret key base from `AVWE_SECRET_KEY_BASE` in
prod. It is started by the application when `config :avwe, AvweWeb.Endpoint`
is set (dev and prod), as telnet and MCP are; tests start their own.

### 3.2 Pages

- **`/` the lobby** (`LobbyLive`): the running worlds (name, tagline) and
  their bodies (name, description, free or being played). Choosing a free
  body opens its page. A body someone holds is shown and cannot be chosen; a
  race for it is refused at the page with the same words as telnet's. No
  "watch" yet (M2b).
- **`/play/:world/:body`** (`PlayLive`), described below.

### 3.3 The play page

Mounting twice is how LiveView works (a plain request, then the socket), so
the session is started only in the connected mount, with the LiveView as its
sink and `scenes: true`. The session ending (the world stopped, the process
gone) shows a notice and a link back to the lobby, and the lease is released
when the page closes, as for any sink.

The page has four parts:

1. **The map**: a `<canvas>` drawn by one hook, `SceneCanvas`. The hook only
   draws what it is sent (glyphs from the legend, shaded by light, nothing
   outside the sight circle) and reports clicks as `{cell}`. It holds no game
   logic: the server decides what a click means and whether it is allowed. A
   click on a place goes there; a click elsewhere names the cell and does
   nothing. It never receives a cell the body cannot see.
2. **The log**: percepts as lines, as telnet shows them, with the routine's
   lines styled apart rather than prefixed (the same `yielded` tracking the
   telnet connection has). Speech and notes arrive as text and are escaped,
   never HTML (the "words are plain text" rule holds on the way in and the
   way out).
3. **The look and the HUD**: the prose look in an `aria-live` region (the
   accessible form of the map, and the proof the two agree), the time and
   light, a banner when the routine has the body ("Your routine has you; act
   to take yourself back"), and the body's affordances as buttons: go to a
   known place, kindle or douse a hearth within reach, stop, wait, read the
   notebook.
4. **The command line**: the same words as telnet, through `Avwe.Commands`,
   for everything the buttons do not cover (`say`, `write`, `follow`,
   `go north 200`). Typing or clicking is the controller's presence: it
   touches the session, so the idle rule works as it does for telnet.

Glyph-only means the map is characters drawn in a monospace face; the
legend, not the hook, decides which. Sprites later are legend entries with a
`sprite` layer and a hook that prefers them: no change to the scene or the
session.

### 3.4 Security

The endpoint is loopback by default and has no accounts, so anyone who can
reach the port can take any free body; exposing it is a decision for the
operator, and the spec does not pretend otherwise. Browser pages get the
secure headers and a content security policy with scripts from `'self'` only
(the hook is bundled, so there is no inline script). All text from other
players is escaped by the templates. A glyph or a colour never reaches the
page as markup: the canvas draws a validated character in a validated colour.

Sobelow starts to matter. `.sobelow-conf` loses `router: :none`, and the
`Config.HTTPS` ignore is replaced by a reasoned decision: TLS belongs to
whatever fronts the endpoint, which only listens on loopback. The router
checks (CSRF, headers, CSP) are met, not ignored.

## 4. Tests

CLAUDE.md applies: every user-facing feature has an end-to-end test through
its real transport.

**Unit.**
- `Commands`: a table of what each command plans to, equal to what telnet
  does today for the same input.
- `Repr`: every ground kind and thing kind has a layer; the config
  validation raises for a bad glyph or colour.
- `Terrain.ground_map/1` agrees with `ground/2` on every cell of the Ember
  Reach and of a small world, and is deterministic.
- `Scene`: sight is 5 cells at night and 50 at noon; bodies and fires appear
  only in sight; the channel is dry in 813 and has water in 812 until the
  source fails at 15:00 and the reaches go silent, one after another
  downstream; cells beyond the circle
  are blank; the scene and the look agree on who is in sight (property
  test); a world with no terrain gives a scene with things and no ground.
- `Session`: scenes only when asked; none when nothing changed; one per
  changing step; ordered with the percepts of the same step; telnet and MCP
  sessions unchanged.

**End to end.**
- Telnet: the existing tests, untouched, after 2.1.
- Web, over the real endpoint with `Phoenix.LiveViewTest`: the lobby lists
  the bodies and refuses a held one; joining pushes a scene; `say` through
  the command line reaches a telnet player; a click on a place starts the
  walk and later scenes move the body; the yielded banner appears after the
  idle time; the page says so when its world stops; a speech of
  `<script>alert(1)</script>` shows as text.
- **The done criterion** (`test/e2e/three_controllers_test.exs`), in Lantern
  Hollow: a telnet player, a web player and an MCP player. Each hears the
  others speak within earshot; the web scene shows the other two at their
  cells and moves them as they walk; the MCP player's `listen` and the telnet
  lines report the web player's arrival and speech; releasing one body
  frees it for the routine in all three views.
- **The browser**, in two layers. The canvas drawing arithmetic (cell to
  pixel, fog, glyph colour by light) is plain functions in their own module
  with `node --test` unit tests and no dependencies; CI runs them (Node is on
  the runners). And a headless-browser end-to-end test of the play page, in
  its own CI job: it opens the page against a running endpoint, waits for the
  first scene, checks the canvas was drawn (the hook also mirrors the scene
  into `data-` attributes, so the test reads state, not pixels), clicks a
  place and sees the walk begin in the log, and keeps a screenshot as a CI
  artifact. That job stays off the required list until it has run stably for a
  while. The page is also driven by hand in a real browser during
  development, with screenshots in the PR.

## 5. Rules

Follow CLAUDE.md. `Commands`, `Repr`, `Scene` and `Terrain.ground_map/1` are
pure core and may not touch the clock, files or sockets; the session, the
region server's cache and everything in `AvweWeb` are runtime. No scene,
glyph or page may be a way to see what a session could not.

**Checks, and what M2 changes in them.** Lint, Test, Dialyzer and Sobelow
are required on every PR (`master` is protected). Expect: a larger Dialyzer
PLT (Phoenix and LiveView add several hundred modules, so a cold build is
slower; it is cached); `@impl Phoenix.LiveView` and a `@spec` on every public
function in `lib/avwe_web/`, as Credo requires; the weekly dependency audit
now also covers Phoenix; an assets step (esbuild) plus the Node tests; and a
separate Browser job (Node and a headless Chromium).

## 6. Delivery

Three pull requests, each green on its own, so that none is the size of the
first:

1. **The core** (2.1 to 2.5): commands, representation layers, the ground
   map, scenes, and sessions that produce them. No web code; the telnet and
   MCP tests are the proof that nothing moved.
2. **The skeleton** (3.1, 3.2, 3.4): Phoenix on Bandit, the endpoint, the
   router, the lobby, headers and Sobelow's new settings, the assets build.
3. **The play page** (3.3), the Browser job, the done-criterion test, and the
   DESIGN.md updates: 5 (layout), 8.4 (layers as built), 9 (the web row), 13 (M2
   split into M2a and M2b), 14.

Order inside the work: 2.1 first (a pure refactor with its own tests), then
2.2 to 2.5, then the web.

## 7. Open questions

1. **The HTTP adapter. Settled (Hysun, 2026-10-06): Bandit.** As 3.1
   explains: v2 of the MCP library pins Ranch 1.8.1 for Cowboy and Bandit
   1.12.5 for Bandit, so Bandit is the one that does not push us backward.
2. **The headless driver. Settled (2026-10-06, left to me): Playwright**
   through `phoenix_test_playwright` with `phoenix_test`. It waits by itself
   for the LiveView socket and the first scene, which is most of what makes a
   page like this flaky; it runs a Chromium pinned by its version, the same
   browser on a laptop and on the runner, where Wallaby needs ChromeDriver to
   match whatever Chrome has updated to; it keeps traces and screenshots as CI
   artifacts (section 4 asks for one); WebKit and Firefox are a config line away,
   which matters to a canvas page that someone will open in Safari; and
   PhoenixTest drives the in-process LiveView tests with the same API. The
   costs are Node and a downloaded Chromium in the Browser job (Node is on the
   runners already for `node --test`), `lazy_html` in test, and a library that
   is pre-1.0 and releases quickly (0.14 in May, 0.18 in September; its client
   `playwright_ex` made five releases in three weeks in September). The lock
   file freezes it, and `mix.exs` pins the minor (`~> 0.18.0`) so an update is
   a choice. Wallaby 0.31 (older, steadier, using the Chrome and ChromeDriver
   already on the runners) is the fallback if the job proves flaky or heavy:
   the browser test is one file. Browser tests are tagged `:browser` and
   excluded from `mix test`; the Test job needs neither Node nor a browser.
3. **MCP and the web endpoint.** The MCP server keeps its own listener (4041)
   in M2. With ArborMCP 2's `Arbor.MCP.HttpPlug` mounts it could later live in
   the Phoenix router: one port, one origin policy. Revisit when the MCP
   adapter moves to v2.
4. **Glyph overrides.** Config keys now (2.2). Whether Quire articles should
   carry them is for Quire.
5. **Keyboard play.** Not in M2a (clicks and the command line). Arrow keys
   walking a fixed distance is an easy addition once the page exists.
6. **Names of bodies not yet met.** The look names every body in sight, so
   the scene does too. DESIGN 8.3 wants names known only once met; that is a
   separate feature and would change the look first.
7. **Binding and exposure.** Loopback only. If the page is ever to be
   reachable beyond it, that needs identity, and TLS in front, before any
   other change.
