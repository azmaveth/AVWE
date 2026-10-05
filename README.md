# AVWE

**Azmaveth's Virtual World Engine** — a headless world simulator.

AVWE owns a world's rules and state, and nothing else. Clients connect and
present the world however they like: a telnet text client, a web canvas, an MCP
server that lets Claude play, or Arbor agents that live there on their own.
Worlds are written in [Quire](https://github.com/azmaveth/quire). The first one
is the Ember Reach.

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Status

M0 scaffolding. A world loads from Quire, its map pins become places and its
characters start at home, and the clock runs deterministically with one system
(daylight). Terrain, heat, water, fire, sessions and the telnet client are next.

## Running it

Requirements: Erlang/OTP 28 and Elixir 1.19 (see `.tool-versions`), and a Quire
checkout next to this one (`../quire`), or `AVWE_QUIRE_ROOT` pointing at Quire's
`data/worlds` folder.

```bash
mix deps.get
mix test
```

```elixir
# iex -S mix
{:ok, _pid} = Avwe.start_world(:ember_reach)
Avwe.now(:ember_reach)          # "813 AR, day 220, 04:00"
Avwe.subscribe(:ember_reach)
Avwe.step(:ember_reach, 120)    # two world hours
flush()                         # {:avwe_events, :ember_reach, [%Avwe.Event{type: :sunrise, ...}]}
Avwe.snapshot(:ember_reach)
```

## License

MIT
