defmodule Avwe.E2E.FireTest do
  @moduledoc """
  End to end over real TCP: Mira lights the kiln-house hearth in the Ember
  Reach before dawn on day 220 of 813 AR, while a watcher looks on, and
  later lets it burn out. One test goes through `Avwe.Session` instead, as
  an agent would: dousing a hearth by its id.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  alias Avwe.{Percept, Session}

  @world :ember_fire
  @moduletag start: {813, day: 220, hour: 4}

  setup %{start: start} = context do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: start))
    on_exit(fn -> Avwe.stop_world(@world) end)

    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))

    if context[:session],
      do: %{port: port},
      else: %{port: port, mira: join(port, "mira")}
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
    expect(mira, "The air is cool.")
    expect(mira, "The kiln-house hearth is cold, with wood laid.")

    act(mira, "kindle")
    expect(mira, "You light the kiln-house hearth.")
    expect(watcher, "Mira Vale lights the kiln-house hearth.")

    # The smoke is at its source, whatever the wind: at least on the wind.
    expect(
      mira,
      ~r/^(You smell woodsmoke on the wind from the south-west\.|The smoke is thick here\.)$/
    )

    send_line(mira, "look")
    expect(mira, "The kiln-house hearth is burning here.")
    expect(mira, "The fire's heat is on your face.")
    expect(mira, ~r/^(Woodsmoke on the wind from the south-west\.|The smoke is thick here\.)$/)

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

  test "lit at 04:00, 8 kg at 5 kW burns low at 10:13 and goes out at 11:06", %{
    port: port,
    mira: mira
  } do
    watcher = join(port, "watch", "You are watching.")

    act(mira, "light the fire")
    expect(mira, "You light the kiln-house hearth.")

    # 1 kg is left after 22 400 s (10:13:20): the step ending 10:14 reports it.
    # At the hearth it is "the fire"; the watcher is told which.
    Avwe.step(@world, 372)
    refute_line(mira, "The fire burns low.")
    Avwe.step(@world, 1)
    expect(mira, "The fire burns low.")
    expect(watcher, "The kiln-house hearth burns low.")

    # The wood is gone after 25 600 s (11:06:40): the step ending 11:07.
    Avwe.step(@world, 52)
    refute_line(mira, "The fire goes out.")
    Avwe.step(@world, 1)
    expect(mira, "The fire goes out.")
    expect(watcher, "The fire at the kiln-house hearth goes out.")

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

  test "a cell off the lit hearth its warmth is faint; 150 m off, its glow shows in the dark",
       %{mira: mira} do
    act(mira, "kindle")
    expect(mira, "You light the kiln-house hearth.")

    send_line(mira, "go north 10")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You stop, 10 m north of where you set out.")

    send_line(mira, "look")
    expect(mira, "The kiln-house hearth is burning here.")
    expect(mira, "You feel a faint warmth from the kiln-house hearth.")

    send_line(mira, "go north 140")
    sync(mira)
    Avwe.step(@world, 3)
    expect(mira, "You stop, 140 m north of where you set out.")

    send_line(mira, "look")
    expect(mira, "A glow shows at the kiln-house hearth, 150 m to the south.")
  end

  test "by seven the air has warmed faster than the ground", %{mira: mira} do
    Avwe.step(@world, 3 * 60)

    send_line(mira, "look")
    expect(mira, "813 AR, day 220, 07:00. The light is low.")
    expect(mira, "The ground is cold.")
  end

  test "at the lodge, the Last Coal's warmth reaches her, and both hearths show once the lodge's is lit",
       %{mira: mira} do
    send_line(mira, "go lodge")
    sync(mira)
    Avwe.step(@world, 8)
    expect(mira, "You arrive at Ashwarden Lodge.")

    send_line(mira, "look")
    expect(mira, "The lodge hearth is cold, with wood laid.")
    expect(mira, "The Last Coal is burning here.")
    expect(mira, "Warmth reaches you from The Last Coal.")

    act(mira, "light the lodge hearth")
    expect(mira, "You light the lodge hearth.")

    send_line(mira, "look")
    expect(mira, "The lodge hearth is burning here.")
    expect(mira, "The Last Coal is burning here.")
    expect(mira, "The fire's heat is on your face. Warmth reaches you from The Last Coal.")
  end

  test "hearths can be named: the coal does not go out, the lodge hearth lights, and a stranger is refused",
       %{mira: mira, port: port} do
    send_line(mira, "go lodge")
    sync(mira)
    Avwe.step(@world, 8)
    expect(mira, "You arrive at Ashwarden Lodge.")

    # Bare, "douse" would mean the nearest hearth, the cold lodge hearth.
    act(mira, "douse the coal")
    expect(mira, "It does not go out.")
    refute_line(mira, "It isn't lit.")

    # Refused at once, by the connection, not by the world.
    send_line(mira, "kindle the kiln-house hearth")
    expect(mira, "There is no hearth called \"kiln-house hearth\" here.")

    watcher = join(port, "watch", "You are watching.")
    send_line(watcher, "douse the coal")
    expect(watcher, "You're only watching.")

    act(mira, "light the lodge hearth")
    expect(mira, "You light the lodge hearth.")

    act(mira, "put out the fire in the lodge hearth")
    expect(mira, "You douse the lodge hearth.")

    act(mira, "douse")
    expect(mira, "It isn't lit.")
  end

  describe "in the afternoon" do
    @describetag start: {813, day: 220, hour: 14}

    test "the air and the clay are warm, and a lit hearth shows by its smoke", %{mira: mira} do
      send_line(mira, "look")
      expect(mira, "813 AR, day 220, 14:00. It is daylight.")
      expect(mira, "The air is warm. The ground is warm underfoot.")

      act(mira, "kindle")
      expect(mira, "You light the kiln-house hearth.")

      send_line(mira, "go north 150")
      sync(mira)
      Avwe.step(@world, 3)
      expect(mira, "You stop, 150 m north of where you set out.")

      send_line(mira, "look")
      expect(mira, "Smoke rises from the kiln-house hearth, 150 m to the south.")
    end
  end

  describe "through a session" do
    @describetag session: true

    test "the Last Coal, doused by name, does not go out" do
      {:ok, mira} = Avwe.connect(@world, body: "mira-vale", controller: :arbor)

      {:ok, _go} = Session.act(mira, :go, target: "ashwarden-lodge")
      Avwe.step(@world, 8)
      assert "You arrive at Ashwarden Lodge." in summaries(mira)

      {:ok, douse} = Session.act(mira, :douse, target: "the-last-coal")
      Avwe.step(@world, 1)

      assert [
               %Percept{
                 intent: ^douse,
                 outcome: :failure,
                 reason: :unquenchable,
                 summary: "It does not go out."
               }
             ] = Enum.filter(percepts(mira), &(&1.kind == :result))

      assert {:ok, %{warmth: %{fire: %{ref: "the-last-coal", level: :warm}}}} =
               Session.look(mira)
    end
  end
end
