# AVWE

**Azmaveth's Virtual World Engine** — a headless world simulator.

AVWE owns a world's rules and state, and nothing else. Clients connect and
present the world however they like: a telnet text client, a web canvas, an MCP
server that lets Claude play, or Arbor agents that live there on their own.
Worlds are written in [Quire](https://github.com/azmaveth/quire). The first one
is the Ember Reach.

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Status

M0 and M1 are built:

- Worlds load from Quire. Map pins become places, and characters start at home
  knowing the way to every pinned place.
- A deterministic clock with daylight, walking, waiting and speech.
- Sessions: any controller can take a body (one at a time) or watch, act with
  intents, and receive percepts. Every intent ends in exactly one result.
- Senses: sight that shrinks at night, and hearing by volume (whisper, talk,
  shout).
- Terrain generated from the map pins, and the Ember: a warm river that the
  812 miracle drains from its source downward. In 813 it is dry, and its
  forgotten source can be found by following the old channel upstream.
- A telnet client.
- Persistence: every intent and advance is journaled, snapshots are taken as
  the world runs, replaying the journal reproduces the world exactly, and a
  restarted or crashed world resumes where it was.
- Weather and heat: a diurnal air temperature, and a heat field where the sun,
  the air, the sky and the warm river warm and cool the ground by material.
  The silt banks steam while the river runs and are cold a year after it
  stops. Energy is conserved and property-tested at any step length.
- Fire and smoke: hearths at the town and the lodge that you can `kindle` and
  `douse`, which burn their fuel, warm the ground, and send smoke downwind
  that bodies smell; the Last Coal burns without fuel and cannot be put out.
- Autopilot: a body nobody holds lives its routine. Mira walks the banks
  before dawn, surveys the bend, warms her hands at the lodge on the way
  home and rests, every day, unattended; on a cold night she lights her
  hearth only while the river's warmth still invites a fire, so her chimney
  goes cold the year after the river does. Take her over mid-journey and give
  her back, and she carries on.

- Memory in the world (M1): Mira carries a survey notebook you can `write`
  in and `read`, and a body remembers what it perceived, so whoever takes it
  next is told "While you were away".
- An MCP server (M1), so Claude can play: join a body, look, act with plans
  that run on while it thinks, speak, wait, write and read, over streamable
  HTTP. Claude has played Mira across two sessions and found the notes from
  the first.

M2a is built: a web client, so a telnet player, a web player and Claude can be
in the world at once. A lobby lists the worlds and their bodies, and a page
plays one: a map of what the body can see, drawn in glyphs on a canvas, the
description of where you are, a log of what happens, buttons for what the body
can do, and a command line that takes telnet's words (see "Playing in a
browser"). The spectator view and the overlays for heat, water and smoke are
next, as M2b ([docs/m2-spec.md](docs/m2-spec.md)).

## Playing

Requirements: Erlang/OTP 28 and Elixir 1.19 (see `.tool-versions`), and a Quire
checkout next to this one (`../quire`), or `AVWE_QUIRE_ROOT` pointing at Quire's
`data/worlds` folder.

```bash
mix deps.get
mix run --no-halt
```

That runs the Ember Reach in real time, one world minute per second, and
keeps its journal and snapshots under `worlds/`, so stopping and starting it
resumes the world where it was (delete `worlds/ember_reach` to start over).
In another terminal:

```bash
telnet localhost 4040
```

Choose Mira Vale (or `watch`), then try `look`, `go to the dry bend`,
`follow the channel upstream`, `go north 200`, `say hello`,
`light the fire`, `douse`, `wait until dawn`, `stop` and `help`. Go to the
lodge to feel the Last Coal; stand by the kiln-house hearth, light it, and
watch it burn low and out over eight world hours. Or choose `watch` and see
Mira keep her day on her own. If you stop acting for ten minutes your body
goes back to its routine, shown as "- " lines, until your next command.
`write The reeds lean north.` keeps a note in her notebook, and `read` (or
`notes`) reads it back; it is still there the next time anyone plays her.

If you ran the Ember Reach before M1, delete `worlds/ember_reach` once: a
world resumed from its saved state keeps its saved characters, so Mira would
have no notebook.

## Playing in a browser

```bash
mix setup          # once: dependencies, esbuild, and the page's script and stylesheet
mix run --no-halt
```

Then open <http://127.0.0.1:4042>. The lobby lists the running worlds and the
bodies in each; choose one that is free. The page shows:

- **The map**: what your body can see, in glyphs (you are `@`, `#` is a place,
  `*` a hearth that burns). It shows the 41 cells around you; "Wider view" shows
  all that is in sight, which at noon is 500 m. At night you see 50 m, and a
  fire shows from far off. Click a place to walk there; click anything else to
  be told what it is.
- **The look**, in words, which says what the map says; **the log** of what
  happens, with what your routine does while you are not acting in grey; and
  **buttons** for what you can do now (go to a place you know, light or put out a
  hearth, stop, wait, read your notebook).
- **The command line**, which takes what telnet takes (`help` lists it).

Typing, pressing and clicking keep your body in your hand; if you do none of them
for ten minutes it goes back to its routine, and a banner says so until you act.
Someone else can be in the same world on telnet, or Claude over MCP, at the same
time. The page only listens on 127.0.0.1 and has no accounts, so anyone who can
reach the port can take a free body.

## Playing with Claude

`mix run --no-halt` also serves MCP at `http://127.0.0.1:4041/mcp`.
`.mcp.json` in this folder points Claude Code at it, so a Claude Code session
started here (with the server running, and the `avwe` server approved) has
the tools: `bodies`, `join`, `look`, `act`, `say`, `wait`, `write`, `read`,
`listen` and `leave`. Ask it to play Mira.

To play over MCP by hand, or to see what Claude sees:

```bash
scripts/mcp_call.py bodies
scripts/mcp_call.py join '{"body": "Mira"}'
scripts/mcp_call.py act '{"steps": [{"verb": "go", "target": "the dry bend"}, {"verb": "wait", "params": {"minutes": 20}}]}'
scripts/mcp_call.py write '{"text": "The reeds at the bend lean north."}'
scripts/mcp_call.py --leave
```

The script keeps its MCP session in `tmp/mcp_session`; `--new` starts a new
one, and `--json` prints the structured result too. The world does not wait:
in dev a world minute passes every real second, whether or not anyone acts.

To see the river run, and hear it fall silent, start the Ember Reach in 812,
an hour before its source fails:

```elixir
# iex -S mix
Avwe.stop_world(:ember_reach)
Avwe.start_world(:ember_reach, start: {812, day: 200, hour: 14}, clock: {:live, 1_000})
```

## From Elixir

```elixir
# iex -S mix
{:ok, mira} = Avwe.connect(:ember_reach, body: "mira-vale")
Avwe.Session.look(mira)
Avwe.Session.act(mira, :go, target: "the-dry-bend")
flush()   # {:avwe_percepts, _, [%Avwe.Percept{summary: "You set off toward The Dry Bend."}]} ...
```

## Tests and checks

```bash
mix test                  # about two minutes
mix lint                  # format, unused deps, compiler warnings, credo: about a second
mix dialyzer              # types; the first run builds the PLTs, about a minute
scripts/sobelow           # security scan
npm test --prefix assets  # the page's drawing arithmetic, with Node (nothing to install)
mix test --only playwright   # the page in a real browser; see below for the one-time install
mix hex.audit             # known advisories in the dependencies; needs the network
```

CI (`.github/workflows/`) runs all of these on every pull request. To run the
quick ones before each commit and push, turn on the hooks once per clone:

```bash
git config core.hooksPath .githooks
```

`pre-commit` runs `mix lint`; `pre-push` runs Dialyzer and Sobelow.
`git commit --no-verify` skips a hook once; CI does not skip.

The browser tests (`test/browser`) drive Chromium through Playwright against the
page: they click the map, type a line, reload, and fail on anything the page
writes to the console. `mix test` leaves them out, so nothing below is needed
for it. To run them, install Playwright once, then build the page's script:

```bash
npm ci --prefix assets
(cd assets && npx playwright install chromium)
mix assets.build
mix test --only playwright     # PW_TRACE=true PW_SCREENSHOT=true keeps a trace and a
                               # screenshot of every test in tmp/playwright
```

CI runs them as the `Browser` workflow, which master does not require yet.

End-to-end tests in `test/e2e/` play through the real transports: telnet over
TCP, sessions as agents use them, MCP over real HTTP, and the web client over a
real socket. `three_controllers_test.exs` has a telnet player, a web player and
an MCP player in one world, each perceiving the others.

## License

MIT
