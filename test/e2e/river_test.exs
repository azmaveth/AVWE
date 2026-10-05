defmodule Avwe.E2E.RiverTest do
  @moduledoc """
  End to end over real TCP: the Ember Reach on day 200 of 812 AR, an hour
  before the river's source fails. Checks the simulation against canon: "the
  Ember river falls silent at the Dry Bend". The day before, the banks still
  steam: the town "sits where the silt used to steam at dusk".
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :ember_812
  @moduletag start: {812, day: 200, hour: 14}

  setup %{start: start} do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: start))
    on_exit(fn -> Avwe.stop_world(@world) end)

    %{port: Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))}
  end

  test "Mira hears the river beside the town fall silent", %{port: port} do
    mira = join(port, "mira")
    expect(mira, "The river runs 60 m to the east, warm.")

    Avwe.step(@world, 3 * 60)
    expect(mira, "The river falls silent.")

    send_line(mira, "look")
    expect(mira, "812 AR, day 200, 17:00. It is daylight.")
    expect(mira, "The old channel runs 60 m to the east.")
  end

  test "a watcher sees the spring stop, then the silence move downstream past the Dry Bend, the town and the docks",
       %{port: port} do
    watcher = join(port, "watch", "You are watching.")
    expect(watcher, "The Ember is running.")

    Avwe.step(@world, 3 * 60)

    expect(watcher, "The spring stops welling up.")
    expect(watcher, "The river falls silent near The Source.")
    expect(watcher, "The river falls silent near The Dry Bend.")
    expect(watcher, "The river falls silent near Ember Reach.")
    expect(watcher, "The river falls silent near Willow Docks.")

    send_line(watcher, "look")
    expect(watcher, "The Ember is dry.")
  end

  test "Mira can follow the running river upstream to its source before it fails", %{port: port} do
    mira = join(port, "mira")

    send_line(mira, "follow the river upstream")
    sync(mira)
    Avwe.step(@world, 45)

    expect(mira, "You find The Source.")
    expect(mira, "You reach the head of the channel.")

    # The source fails at 15:00; the stretch at the source goes quiet minutes later.
    Avwe.step(@world, 45)
    expect(mira, "The spring stops welling up.")
    expect(mira, "The river falls silent.")
  end

  describe "the day before the source fails" do
    @describetag start: {812, day: 199, hour: 14}

    test "Mira, on the silt beside the channel, sees the banks steam from mid-afternoon all night",
         %{port: port} do
      mira = join(port, "mira")

      send_line(mira, "go east 90")
      sync(mira)
      Avwe.step(@world, 2)
      expect(mira, "You stop, 90 m east of where you set out.")

      Avwe.step(@world, 4 * 60 - 2)
      expect(mira, "Steam begins to rise from the banks.")

      send_line(mira, "look")
      expect(mira, ~r/^812 AR, day 199, 18:00\./)
      expect(mira, "The ground is silt, pale and fine.")
      expect(mira, "Steam lifts off the silt.")

      Avwe.step(@world, 4 * 60)
      send_line(mira, "look")
      expect(mira, "812 AR, day 199, 22:00. It is dark.")
      expect(mira, "The river runs 30 m to the west, warm, with steam lifting off it.")
      expect(mira, "Steam lifts off the silt.")
    end
  end
end
