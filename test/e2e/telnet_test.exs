defmodule Avwe.E2E.TelnetTest do
  @moduledoc """
  End to end over real TCP: a telnet player in the Ember Reach, starting at
  04:00 on day 220 of 813 AR with a manual clock.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :ember_telnet

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts())
    on_exit(fn -> Avwe.stop_world(@world) end)

    telnet = start_supervised!({Avwe.Telnet, port: 0})
    %{port: Avwe.Telnet.port(telnet)}
  end

  describe "joining" do
    test "a player chooses Mira and looks around", %{port: port} do
      socket = connect(port)

      expect(socket, "Welcome to AVWE")
      expect(socket, "You are in The Ember Reach. A river valley remembering its last summer.")
      expect(socket, "Who will you be?")
      expect(socket, "  Mira Vale - A cartographer who maps the dying riverlands")
      expect(socket, "  watch - watch without a body")

      send_line(socket, "mira")
      expect(socket, "You are Mira Vale.")
      expect(socket, "813 AR, day 220, 04:00. It is dark.")
      expect(socket, "You are Mira Vale, at Ember Reach.")
      expect(socket, "A river town of kiln-houses and willow docks")
      expect(socket, "You see no one else.")

      expect(
        socket,
        "You know the way to: Ashwarden Lodge (430 m north-west), The Dry Bend (730 m north-east), Willow Docks (290 m south-east)."
      )
    end

    test "nobody else can take Mira, but they can watch her", %{port: port} do
      mira = join(port, "mira")

      watcher = connect(port)
      expect(watcher, "  Mira Vale (being played)")
      expect(watcher, "watch without a body")
      send_line(watcher, "mira")
      expect(watcher, "Mira Vale is already being played. Choose someone else, or watch.")
      send_line(watcher, "watch")
      expect(watcher, "You are watching. Nobody can see you.")
      expect(watcher, "Mira Vale is at Ember Reach.")

      send_line(mira, "go dry bend")
      sync(mira)
      Avwe.step(@world, 10)

      expect(watcher, "Mira Vale leaves, heading toward The Dry Bend.")
      expect(watcher, "Mira Vale arrives at The Dry Bend.")

      send_line(watcher, "go docks")
      expect(watcher, "You're only watching.")
    end

    test "quitting frees the body for someone else", %{port: port} do
      first = join(port, "mira")
      send_line(first, "quit")
      expect(first, "Goodbye.")
      assert closed?(first)

      eventually(fn ->
        {:ok, bodies} = Avwe.bodies(@world)
        not hd(bodies).taken
      end)

      second = join(port, "mira")
      expect(second, "You know the way to:")
    end

    test "dropping the connection frees the body too", %{port: port} do
      first = join(port, "mira")
      :gen_tcp.close(first)

      eventually(fn ->
        {:ok, bodies} = Avwe.bodies(@world)
        not hd(bodies).taken
      end)
    end

    test "with several worlds running, the player chooses one", %{port: port} do
      {:ok, _pid} =
        Avwe.start_world(:hollow_choice, quire: lantern_hollow(), start: {1, hour: 12})

      on_exit(fn -> Avwe.stop_world(:hollow_choice) end)

      socket = connect(port)
      expect(socket, "Which world?")
      expect(socket, "  Lantern Hollow")
      expect(socket, "  The Ember Reach")

      send_line(socket, "atlantis")
      expect(socket, ~s(There's no world called "atlantis".))

      send_line(socket, "hollow")
      expect(socket, "You are in Lantern Hollow.")
      expect(socket, "watch without a body")
      send_line(socket, "odo")
      expect(socket, "You are Odo.")
      expect(socket, "You are Odo, at Far Tower.")
    end

    test "with no worlds running, the player is told so", %{port: port} do
      :ok = Avwe.stop_world(@world)

      socket = connect(port)
      expect(socket, "No worlds are running right now.")
      assert closed?(socket)
    end
  end

  describe "playing as Mira" do
    setup %{port: port}, do: %{mira: join(port, "mira")}

    test "she walks to the Dry Bend", %{mira: mira} do
      send_line(mira, "go to the dry bend")
      sync(mira)
      Avwe.step(@world, 10)

      expect(mira, "You set off toward The Dry Bend.")
      expect(mira, "You're a quarter of the way to The Dry Bend.")
      expect(mira, "You're halfway to The Dry Bend.")
      expect(mira, "You're nearly at The Dry Bend.")
      expect(mira, "You arrive at The Dry Bend.")

      send_line(mira, "look")
      expect(mira, "813 AR, day 220, 04:10. It is dark.")
      expect(mira, "You are Mira Vale, at The Dry Bend.")
      expect(mira, "The year the Ember river fell silent at the Dry Bend")
    end

    test "she stops halfway to the docks", %{mira: mira} do
      send_line(mira, "go willow docks")
      sync(mira)
      Avwe.step(@world, 2)
      expect(mira, "You're halfway to Willow Docks.")

      send_line(mira, "look")
      expect(mira, "You are on your way to Willow Docks.")

      send_line(mira, "stop")
      sync(mira)
      Avwe.step(@world, 1)
      expect(mira, "You stop short of Willow Docks.")

      send_line(mira, "look")
      expect(mira, ~r/^You are Mira Vale, \d+ m [a-z-]+ of Willow Docks\.$/)
    end

    test "she waits for dawn", %{mira: mira} do
      send_line(mira, "wait until dawn")
      sync(mira)
      Avwe.step(@world, 120)

      expect(mira, "You settle in to wait for dawn.")
      expect(mira, "The sun rises.")
      expect(mira, "You finish waiting.")

      send_line(mira, "time")
      expect(mira, "813 AR, day 220, 06:00")
    end

    test "she talks to herself", %{mira: mira} do
      send_line(mira, "say Where did you go?")
      sync(mira)
      Avwe.step(@world, 1)

      expect(mira, ~s(You say, "Where did you go?"))
    end

    test "she gets help with mistakes", %{mira: mira} do
      send_line(mira, "go to atlantis")
      expect(mira, ~s(You don't know a place called "atlantis".))

      send_line(mira, "go r")
      expect(mira, "Which do you mean: ")

      send_line(mira, "dance")
      expect(mira, ~s(I don't understand "dance". Type help for a list of commands.))

      send_line(mira, "say")
      expect(mira, "Say what?")

      send_line(mira, "wait forever")
      expect(mira, "Wait how long?")

      send_line(mira, "stop")
      sync(mira)
      Avwe.step(@world, 1)
      expect(mira, "You aren't doing anything.")

      send_line(mira, "help")
      expect(mira, "Commands:")
      expect(mira, "  quit              leave")
    end

    test "telnet negotiation bytes are ignored", %{mira: mira} do
      :ok = :gen_tcp.send(mira, <<255, 251, 1, 255, 253, 3>> <> "look\r\n")
      expect(mira, "You are Mira Vale, at Ember Reach.")
    end

    test "everyone sees the same sunrise", %{port: port, mira: mira} do
      watcher = join(port, "watch", "You are watching.")

      Avwe.step(@world, 120)

      expect(mira, "The sun rises.")
      expect(watcher, "The sun rises.")
    end
  end

  describe "the dry river" do
    setup %{port: port}, do: %{mira: join(port, "mira")}

    test "Mira follows the old channel upstream and finds the forgotten source", %{mira: mira} do
      send_line(mira, "look")
      expect(mira, ~r/^The old channel runs 60 m to the east\. Upstream is to the/)
      lines = expect(mira, "You know the way to:")
      refute Enum.any?(lines, &(&1 =~ "The Source"))

      send_line(mira, "follow the channel upstream")
      sync(mira)
      Avwe.step(@world, 45)

      expect(mira, "You set off upstream along the channel.")

      expect(
        mira,
        "You find The Source. A hollow ringed with pale stones, where the Ember once welled up warm."
      )

      expect(mira, "You reach the head of the channel.")

      send_line(mira, "look")
      expect(mira, "You are Mira Vale, at The Source.")
      expect(mira, "You stand in the old river channel, on cracked mud.")
      expect(mira, "This is where the old channel begins.")

      send_line(mira, "go ember reach")
      sync(mira)
      Avwe.step(@world, 30)
      expect(mira, "You arrive at Ember Reach.")

      send_line(mira, "look")
      expect(mira, ~r/^You know the way to: .*The Source \(\d+ m north(-east)?\)/)
    end

    test "she walks a set distance in a compass direction", %{mira: mira} do
      send_line(mira, "go north 200")
      sync(mira)
      Avwe.step(@world, 5)

      expect(mira, "You set off to the north.")
      expect(mira, "You stop, 200 m north of where you set out.")
    end

    test "away from the channel there is nothing to follow", %{mira: mira} do
      send_line(mira, "go lodge")
      sync(mira)
      Avwe.step(@world, 10)
      expect(mira, "You arrive at Ashwarden Lodge.")

      send_line(mira, "look")
      expect(mira, "Dry grass covers the ground.")

      send_line(mira, "follow upstream")
      sync(mira)
      Avwe.step(@world, 1)
      expect(mira, "There's no channel here to follow.")
    end

    test "help explains following and walking", %{mira: mira} do
      send_line(mira, "help")
      expect(mira, "  follow upstream   follow the river channel (or: follow downstream)")
    end
  end
end
