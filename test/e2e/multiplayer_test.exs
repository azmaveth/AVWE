defmodule Avwe.E2E.MultiplayerTest do
  @moduledoc """
  End to end over real TCP: four telnet players in Lantern Hollow at noon.
  Wren and Tamsin are on Hollow Green, Pell at the Mill Pond 70 m east, Odo
  in the Far Tower 1.5 km east.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :hollow_telnet

  setup do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)

    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    Map.new(~w(wren tamsin pell odo)a, &{&1, join(port, Atom.to_string(&1))})
  end

  test "talk is heard on the green, not at the pond or the tower", p do
    send_line(p.wren, "say Good morning")
    sync(p.wren)
    Avwe.step(@world, 1)

    expect(p.wren, ~s(You say, "Good morning"))
    expect(p.tamsin, ~s(Wren says, "Good morning"))
    refute_line(p.pell, "Good morning")
    refute_line(p.odo, "Good morning")
  end

  test "a shout carries to the pond, not the tower", p do
    send_line(p.wren, "shout Fire at the mill!")
    sync(p.wren)
    Avwe.step(@world, 1)

    expect(p.tamsin, ~s(Wren shouts, "Fire at the mill!"))
    expect(p.pell, ~s(Wren shouts from the west, "Fire at the mill!"))
    refute_line(p.odo, "Fire")
  end

  test "a whisper reaches only someone close by", p do
    send_line(p.wren, "whisper the tower is empty")
    sync(p.wren)
    Avwe.step(@world, 1)

    expect(p.tamsin, ~s(Wren whispers, "the tower is empty"))
    refute_line(p.pell, "tower is empty")
  end

  test "people see someone arrive, and meet them", p do
    send_line(p.odo, "go hollow green")
    sync(p.odo)
    Avwe.step(@world, 20)

    expect(p.odo, "You arrive at Hollow Green.")
    expect(p.wren, "Odo arrives at Hollow Green.")
    expect(p.pell, "Odo arrives at Hollow Green.")

    send_line(p.odo, "look")
    expect(p.odo, "You are Odo, at Hollow Green.")
    lines = expect(p.odo, "You know the way to:")
    assert "Tamsin is here." in lines
    assert "Wren is here." in lines
  end

  test "people see someone leave", p do
    send_line(p.tamsin, "go to the mill pond")
    sync(p.tamsin)
    Avwe.step(@world, 1)

    expect(p.wren, "Tamsin leaves, heading toward Mill Pond.")
    expect(p.pell, "Tamsin arrives at Mill Pond.")
  end

  test "at night, the green can't see the pond", p do
    Avwe.step(@world, 10 * 60)
    expect(p.wren, "The sun sets.")

    send_line(p.tamsin, "go mill pond")
    sync(p.tamsin)
    Avwe.step(@world, 1)

    expect(p.wren, "Tamsin leaves, heading toward Mill Pond.")
    expect(p.pell, "Tamsin arrives at Mill Pond.")
    refute_line(p.wren, "arrives")
  end
end
