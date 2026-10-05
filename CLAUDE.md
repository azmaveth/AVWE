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

## Commands

```bash
mix test
mix format
mix credo --strict
mix compile --warnings-as-errors
```

Tests use a copy of the Ember Reach in `test/fixtures/quire/`. Running a world
in dev reads Quire from `../quire/data/worlds` or `AVWE_QUIRE_ROOT`.
