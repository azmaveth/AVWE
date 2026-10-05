# AVWE

**Azmaveth's Virtual World Engine** — a headless world simulator.

AVWE owns a world's rules and state, and nothing else. Clients connect and
present the world however they like: a telnet text client, a web canvas, an MCP
server that lets Claude play, or Arbor agents that live there on their own.
Worlds are written in [Quire](https://github.com/azmaveth/quire). The first one
is the Ember Reach.

The design is in [docs/DESIGN.md](docs/DESIGN.md).

## Status

M0 in progress. Built so far:

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

Next: autopilot for bodies nobody is controlling.

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
watch it burn low and out over eight world hours.

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

## Tests

```bash
mix test
```

End-to-end tests in `test/e2e/` play through the real transports: telnet over
TCP, and sessions as agents use them.

## License

MIT
