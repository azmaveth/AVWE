# CLAUDE.md

AVWE is a headless world simulator in Elixir. Read `docs/DESIGN.md` before
changing anything structural; it records the decisions and the reasons.

## Rules

- **The simulation core does no I/O.** `Avwe.Region`, `Avwe.Tick`, systems and
  `Avwe.Quire.Seed` are pure. Files, sockets, the wall clock and LLMs belong in
  `Avwe.Quire`, servers and adapters.
- **Determinism.** Systems use only `Avwe.Tick.rng/2` for randomness, never
  plain `:rand`. Never depend on map iteration order; use
  `Region.with_components/2`, which sorts. Use `tick.dt`; never assume a step
  is one minute. Moments in time are checked with `Tick.crossed?/3`.
- **Quire is canon and read-only.** AVWE never writes to Quire's files except
  the chronicle (M4).
- **No back doors.** Every controller (human, Arbor agent, Claude) will act
  through the same intent/percept protocol.
- Pure modules follow construct-reduce-convert: `new`, reducers that take and
  return the struct, converters at the end.
- **Every user- or agent-facing feature gets an end-to-end test** through its
  real transport (`test/e2e/`): telnet over TCP with `Avwe.Test.TelnetClient`,
  sessions as agents use them, MCP over real HTTP with `Avwe.Test.MCPClient`
  (ExMCP's client; `test/e2e/mcp_*_test.exs`), the web client over a real
  socket with `Avwe.Test.HTTPClient` and `Avwe.Test.WebSocketClient`
  (`test/e2e/web_*_test.exs`; the pages' own logic is in `test/avwe_web/`,
  through `Avwe.Test.WebCase`; `three_controllers_test.exs` is M2's done
  criterion), and later Arbor. Before
  stepping the world after a telnet command, call `TelnetClient.sync/1`; a
  tool call that waits on world time is started with `MCPClient.calling/5`
  and stepped with `step_until_done/4`.
- **A test does not race a short real-time window.** A test that a call keeps
  the body in hand (a session or a Mind yields it after `:idle_after` real ms
  without one) opens the session with a long window (the default is ten
  minutes) and drives the timer itself with `Avwe.Test.Idle`: `presence/2` for
  a call that should keep the body, `expire/1` for the window running out. The
  session of a telnet player, a page or an MCP player is `session_of/2`
  (`Avwe.Test.WebCase`). A sleep against 100-300 ms is overrun when the
  machine is busy (one busy loop per core shows it). A test that only waits
  for the yield may keep a short window: a slow machine makes it later, not
  wrong.
- **Words are plain text.** Speech and notebook pages are cleaned in
  `Avwe.Actions` (escape sequences, line breaks, control characters) so no
  player's words can forge another's lines or reach a terminal. Anything new
  that carries a player's text to other players gets the same.
- **Every intent ends in exactly one result event.** New verbs must keep
  this; the property tests in `test/avwe/actions_test.exs` and
  `test/avwe/journeys_test.exs` check it, autopilot's intents included. The
  only results without a percept are autopilot's own quiet waits.
- **Autopilot's intents are derived state.** They are submitted inside the
  tick with `Region.submit/2`, never journaled, and regenerated on replay;
  the brain (`Avwe.Autopilot`) must stay a pure function of the region and
  the tick.
- **Replay must be exact.** `Avwe.Store.rebuild_from_start/1` has to reproduce
  `Region.state_hash/1`; anything that would make live and replay differ
  (reading map order, the wall clock, `:rand` without `Tick.rng`) is a bug.
  `test/e2e/persistence_test.exs` checks it.

## Commands

```bash
mix test
mix test --include perf     # also runs the per-step cost bound (< 10 ms)
mix test --only playwright  # the page in a real browser (test/browser); needs
                            # `npm ci --prefix assets` and, in assets/, `npx playwright
                            # install chromium` once, and `mix assets.build`
mix setup                   # once: deps, esbuild, and the web client's bundle
npm test --prefix assets    # the page's drawing arithmetic, with Node's own runner
                            # (CI runs it; nothing to install, Node 20 or later)
mix assets.build            # the bundle again, after changing assets/ (the dev server
                            # rebuilds it by itself)
mix format
mix lint                    # format check, unused deps, compile with warnings as
                            # errors, credo --strict: about a second warm
mix dialyzer                # types; the first run builds the PLTs (about a minute)
scripts/sobelow             # security scan (mix sobelow, minus the mix.lock noise)
mix hex.audit               # advisories in the locked deps; needs the network
```

## Checks: hooks and CI

Everything above runs in CI (`.github/workflows/`) for every pull request and
push to master: Lint, Test, Dialyzer and Sobelow in `ci.yml`, and
`mix hex.audit` in `audit.yml`, which also runs weekly because advisories
appear without any change here. A change is not done until they all pass.
`browser.yml` runs the Playwright tests the same way, but it is new and
heavy (Node packages, a downloaded Chromium), so master does not require it
yet; when it fails, look anyway, and its artifact `browser` has a trace and a
screenshot of each test that failed. When a Node script is changed, run it
under CI's Node (24) first: `cd assets && npx -y node@24 --test`.

`.githooks/` has the same checks for local use; turn them on once per clone
with `git config core.hooksPath .githooks`. `pre-commit` runs `mix lint` when
Elixir files or deps changed; `pre-push` runs Dialyzer and Sobelow (a few
seconds once the PLTs exist). The tests are CI-only (about two minutes), and
the audit needs the network, so neither is a hook. `--no-verify` skips a hook
once; CI has no such switch.

What to do with a finding, in order: fix it; or, if it was looked at and is
fine, say so where the tool reads it, with the reason beside it, so the next
finding of that kind still fails:

- **Sobelow:** a `# sobelow_skip ["Module"]` comment above the function (see
  `lib/avwe/store.ex`). Ignoring a whole check goes in `.sobelow-conf`, only
  for one that cannot apply (`Config.HTTPS`: nothing here terminates TLS; every
  listener is on loopback, and whatever exposes one puts TLS in front).
- **Dialyzer:** fix the spec or the code. There is no ignore file; if one is
  ever needed, it is `.dialyzer_ignore.exs` with a comment per entry.
- **Advisories:** update the dependency; if no fixed release exists and the
  affected code is not reachable, add the id to `hex: [ignore_advisories: ...]`
  in `mix.exs` with the reason. Hex warns when an entry stops matching.
- **Credo:** fix it. It runs `mix credo --strict` with Credo's default checks
  plus the opt-in ones in `.credo.exs`, each enabled once the code had no
  findings for it. Turning one off, there or with a `# credo:disable` comment,
  needs the reason beside it. In practice: public functions in `lib/` carry a
  `@spec`, `@impl` names its behaviour (`@impl GenServer`, never `@impl true`),
  `alias` comes before `require`, and a function in `lib/` that passes an ABC
  size of 60 is split rather than excused.

Tests use worlds in `test/fixtures/quire/`: a copy of the Ember Reach, and
Lantern Hollow, a tiny world laid out to test hearing and sight ranges (fire
and smoke tests add hearths and a wind to it through start options).
`Avwe.Test.Fixtures.ember_reach_opts/1` starts the Ember Reach with its real
settings (terrain, river, the 812 miracle) from the fixture copy, and
`Avwe.Test.Ember.region/2` builds its region directly for unit tests.
`mix run --no-halt` in dev runs the Ember Reach live (one world minute per
second) with telnet on port 4040, MCP at `http://127.0.0.1:4041/mcp` and the web
client at `http://127.0.0.1:4042` (after `mix setup`),
reading Quire from `../quire/data/worlds` or `AVWE_QUIRE_ROOT`. `.mcp.json`
points a Claude Code session in this folder at that server, and
`scripts/mcp_call.py <tool> '<json>'` plays it by hand (stdlib Python; the
session id is kept in `tmp/mcp_session`).
