defmodule Avwe.E2E.SmokeTest do
  @moduledoc """
  End to end over real TCP: Lantern Hollow at noon with a bonfire laid on
  Hollow Green and a breath of wind from the north, too light to carry the
  smoke off at once. Wren lights it and stands in the smoke; Tamsin, 200 m
  downwind, gets a faint whiff of it a few minutes later.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :hollow_smoke
  @bonfire [
    id: "green-bonfire",
    at: "hollow-green",
    name: "the bonfire on the green",
    fuel_kg: 8.0,
    power_w: 40_000.0
  ]

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        hearths: [@bonfire],
        climate: [wind: [from: "north", m_s: 0.2]]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)

    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    %{wren: join(port, "wren"), tamsin: join(port, "tamsin")}
  end

  test "the smoke is thick at the bonfire, on the wind 50 m off, and faint 200 m downwind", %{
    wren: wren,
    tamsin: tamsin
  } do
    send_line(tamsin, "go south 200")
    sync(tamsin)
    Avwe.step(@world, 4)
    expect(tamsin, "You stop, 200 m south of where you set out.")

    send_line(wren, "kindle")
    sync(wren)
    Avwe.step(@world, 1)
    expect(wren, "You light the bonfire on the green.")

    send_line(wren, "look")
    expect(wren, "The bonfire on the green is burning here.")
    expect(wren, "The smoke from the bonfire on the green is thick.")

    Avwe.step(@world, 6)
    expect(tamsin, "You smell woodsmoke, faint, from the north.")

    send_line(tamsin, "look")
    expect(tamsin, "Woodsmoke, faint, from the north.")

    send_line(wren, "go south 50")
    sync(wren)
    Avwe.step(@world, 1)
    expect(wren, "You stop, 50 m south of where you set out.")

    send_line(wren, "look")
    expect(wren, "Woodsmoke on the wind from the north.")
  end
end
