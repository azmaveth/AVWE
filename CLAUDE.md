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
  sessions as agents use them, and later MCP and Arbor. Before stepping the
  world after a telnet command, call `TelnetClient.sync/1`.
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
mix format
mix credo --strict
mix compile --warnings-as-errors
mix test --include perf     # also runs the per-step cost bound (< 10 ms)
```

Tests use worlds in `test/fixtures/quire/`: a copy of the Ember Reach, and
Lantern Hollow, a tiny world laid out to test hearing and sight ranges (fire
and smoke tests add hearths and a wind to it through start options).
`Avwe.Test.Fixtures.ember_reach_opts/1` starts the Ember Reach with its real
settings (terrain, river, the 812 miracle) from the fixture copy, and
`Avwe.Test.Ember.region/2` builds its region directly for unit tests.
`mix run --no-halt` in dev runs the Ember Reach live (one world minute per
second) with telnet on port 4040, reading Quire from `../quire/data/worlds` or
`AVWE_QUIRE_ROOT`.
