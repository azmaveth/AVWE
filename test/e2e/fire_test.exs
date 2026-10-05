defmodule Avwe.E2E.FireTest do
  @moduledoc """
  End to end over real TCP: Mira lights the kiln-house hearth in the Ember
  Reach before dawn on day 220 of 813 AR, while a watcher looks on, and
  later lets it burn out.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :ember_fire

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts())
    on_exit(fn -> Avwe.stop_world(@world) end)

    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    %{port: port, mira: join(port, "mira")}
  end

  # Sends a command and runs the world a minute, so its result comes back.
  defp act(socket, line) do
    send_line(socket, line)
    sync(socket)
    Avwe.step(@world, 1)
  end

  test "Mira lights the hearth, feels its heat, and douses it; a watcher sees both", %{
    port: port,
    mira: mira
  } do
    watcher = join(port, "watch", "You are watching.")

    send_line(mira, "look")
    expect(mira, "The kiln-house hearth is cold, with wood laid.")

    act(mira, "kindle")
    expect(mira, "You light the kiln-house hearth.")
    expect(watcher, "Mira Vale lights the kiln-house hearth.")

    send_line(mira, "look")
    expect(mira, "The kiln-house hearth is burning here.")
    expect(mira, "The fire's heat is on your face.")

    act(mira, "kindle")
    expect(mira, "It is already lit.")

    act(mira, "douse")
    expect(mira, "You douse the kiln-house hearth.")
    expect(watcher, "Mira Vale douses the kiln-house hearth.")

    act(mira, "put out the fire")
    expect(mira, "It isn't lit.")

    send_line(watcher, "look")
    expect(watcher, "The Last Coal is burning.")
    refute_line(watcher, "kiln-house hearth is burning")
  end

  test "lit at 04:00, 8 kg at 5 kW burns low at 10:13 and goes out at 11:06", %{mira: mira} do
    act(mira, "light the fire")
    expect(mira, "You light the kiln-house hearth.")

    # 1 kg is left after 22 400 s (10:13:20): the step ending 10:14 reports it.
    Avwe.step(@world, 372)
    refute_line(mira, "The fire burns low.")
    Avwe.step(@world, 1)
    expect(mira, "The fire burns low.")

    # The wood is gone after 25 600 s (11:06:40): the step ending 11:07.
    Avwe.step(@world, 52)
    refute_line(mira, "The fire goes out.")
    Avwe.step(@world, 1)
    expect(mira, "The fire goes out.")

    send_line(mira, "time")
    expect(mira, "813 AR, day 220, 11:07")

    send_line(mira, "look")
    expect(mira, "The kiln-house hearth is cold and empty.")
  end

  test "far from any hearth there is nothing to light", %{mira: mira} do
    send_line(mira, "go north 200")
    sync(mira)
    Avwe.step(@world, 5)
    expect(mira, "You stop, 200 m north of where you set out.")

    act(mira, "kindle")
    expect(mira, "There is no hearth here.")
  end
end
