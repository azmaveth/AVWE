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

    # The banks steam once their silt is, on average, 12 K over the air: with
    # this air curve the town's reach crosses that at about 17:10, toward
    # evening ("the silt used to steam at dusk"), and clears at about 07:30
    # the next morning as the air warms faster than the silt.
    test "Mira, on the silt beside the channel, sees the banks steam from the evening to the morning",
         %{port: port} do
      mira = join(port, "mira")

      send_line(mira, "go east 90")
      sync(mira)
      Avwe.step(@world, 2)
      expect(mira, "You stop, 90 m east of where you set out.")

      send_line(mira, "look")
      expect(mira, "The ground is silt, pale and fine.")
      expect(mira, "The river runs 30 m to the west, warm. Upstream")
      refute_line(mira, "Steam lifts off the silt.")

      Avwe.step(@world, 3 * 60 - 2)
      refute_line(mira, "Steam begins to rise")
      Avwe.step(@world, 60)
      expect(mira, "Steam begins to rise from the banks.")

      send_line(mira, "look")
      expect(mira, ~r/^812 AR, day 199, 18:00\./)
      expect(mira, "The river runs 30 m to the west, warm, with steam lifting off it.")
      expect(mira, "Steam lifts off the silt.")

      Avwe.step(@world, 4 * 60)
      send_line(mira, "look")
      expect(mira, "812 AR, day 199, 22:00. It is dark.")
      expect(mira, "The river runs 30 m to the west, warm, with steam lifting off it.")
      expect(mira, "The air is cool. The ground is hot underfoot. Steam lifts off the silt.")

      # By 07:40 the banks as a whole have stopped steaming, though the silt
      # nearest the channel, where Mira stands, is still over the margin: one
      # rule for steam, so the look agrees with the percept and the river.
      Avwe.step(@world, 9 * 60 + 40)
      expect(mira, "The steam over the banks thins and is gone.")

      send_line(mira, "look")
      expect(mira, "812 AR, day 200, 07:40. It is daylight.")
      expect(mira, "The river runs 30 m to the west, warm. Upstream")
      # The whole line: the steam clause would be appended to it.
      expect(mira, ~r/^(The air is (cool|warm)\. )?The ground is warm underfoot\.$/)
    end

    test "a watcher sees the banks steam place by place down the river, and clear in the morning",
         %{port: port} do
      watcher = join(port, "watch", "You are watching.")

      Avwe.step(@world, 2 * 60 + 30)
      refute_line(watcher, "Steam begins to rise")

      Avwe.step(@world, 90)
      expect(watcher, "Steam begins to rise from the banks near The Source.")
      expect(watcher, "Steam begins to rise from the banks near The Dry Bend.")
      expect(watcher, "Steam begins to rise from the banks near Ember Reach.")
      expect(watcher, "Steam begins to rise from the banks near Willow Docks.")

      Avwe.step(@world, 15 * 60)
      expect(watcher, "The steam over the banks near Ember Reach thins and is gone.")
      expect(watcher, "The steam over the banks near The Source thins and is gone.")
    end
  end
end
