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

### 2.4 The scene

`Avwe.Scene.build(view, body)` (pure) is what the body can see now:

| Field | Meaning |
|---|---|
| `time`, `light` | the world's time, and light from 0.0 to 1.0 |
| `center` | the body's cell |
| `radius` | sight in cells, `Perception.sight_cells/1`: 5 at night, 50 at noon |
| `window` | the square of cells around `center` that holds the circle, as run-length-coded rows of ground kinds; cells outside the circle are blank, because the server sends what is seen and nothing more |
| `water` | the channel cells whose reach is running (not silent), from the river state: the same channel is a dry bed in 813 and water in 812 |
| `things` | what is in sight, each with `id`, `kind`, `cell`, `name` and its glyph layer: bodies, burning and cold hearths, places the body knows, and the fires that show by smoke or glow (`sign`) |
| `legend` | the representation layers (2.2) of the kinds that appear, and only those |
| `body`, `holder` | whose scene it is, and whether a controller or the routine holds it |

**One rule of sight.** `things` is built from the look's own lists
(`bodies`, `hearths`, `fires`, `places`), which gain a `cell` each; the
circle is the look's sight radius. The scene never recomputes visibility, so
the page and the prose cannot disagree (a property test holds it: the
bodies in the look and the bodies in the scene are the same set). A known
place beyond sight is not drawn on the map; it stays in the HUD list as a
button, as telnet lists it.

Run-length coding keeps a typical window (mostly grass) in a few hundred
bytes. The scene is a plain map of strings, numbers and lists, so a client
in any language can read it. An example, at night at the town:

    {"center": [121, 138], "radius": 5.0, "origin": [116, 133], "size": 11,
     "rows": ["g11", "g3s5g3", ...],
     "water": [], "light": 0.0,
     "things": [{"id": "mira-vale", "kind": "body", "cell": [121, 138],
                 "name": "Mira Vale", "glyph": {"char": "@", "color": "#e8d9a0"}}],
     "legend": {"g": {"name": "grass", "glyph": {"char": "\"", "color": "#4c7a3a"}}}}

### 2.5 Sessions produce scenes

`Avwe.connect/2` takes `scenes: true`. Such a session sends its sink
`{:avwe_scene, session, scene}` after a step that changed the scene (the
body moved, sight changed by half a cell or more, something in sight moved
or changed, a reach started or stopped running), and never when nothing
changed. `Session.scene/1` returns the current scene, for the first draw.
A session without the option behaves exactly as today, so telnet and MCP
are not touched. Scenes are built from the same view a step's percepts are,
so the two arrive in step with each other.

**Budget.** With the ground map built, a scene costs under 1 ms warm; the
perf test (`--include perf`) gains a bound for it. A web session adds one
scene per step at most; a slow sink is never waited on.

## 3. The web layer

### 3.1 Phoenix, minimally

Dependencies: `phoenix ~> 1.8`, `phoenix_live_view ~> 1.2`,
`phoenix_html ~> 4.3`, `esbuild` (dev, to bundle one JavaScript file) and
`lazy_html` (test). No Ecto, mailer, gettext or Tailwind: the app has no
database and the pages are simple, so styling is one plain stylesheet. The
modules are hand-written under `lib/avwe_web/` rather than generated, so
nothing is imported that is not used.

The HTTP adapter is Bandit, Phoenix's default, declared in `mix.exs` by
name rather than arriving through another dependency (open question 1).
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

1. **The HTTP adapter.** Bandit, as 3.1 explains: v2 of the MCP library pins
   Ranch 1.8.1 for Cowboy and Bandit 1.12.5 for Bandit, so Bandit is the one
   that does not push us backward. Confirm, or say Cowboy.
2. **The headless driver.** Playwright through `phoenix_test_playwright`
   (0.18) together with `phoenix_test`, which gives one API for in-process
   LiveView tests and real-browser ones, at the cost of Node and a downloaded
   Chromium in CI; or Wallaby (0.31), older and steadier, using the Chrome
   that is already on the runners. Default: Playwright; settle it in the
   third pull request after trying it.
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
