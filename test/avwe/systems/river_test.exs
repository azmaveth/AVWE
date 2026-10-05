defmodule Avwe.Systems.RiverTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Calendar, Event, Region, Terrain}
  alias Avwe.Systems.{Miracles, River}
  alias Avwe.Test.Ember

  @failure Calendar.at(812, day: 200, hour: 15)
  @systems [Miracles, River]

  defp before_failure(minutes_before \\ 60) do
    Ember.region({812, day: 200, hour: 15, minute: -minutes_before}, systems: @systems)
  end

  defp river(region), do: Region.get(region, River.id(), :river)
  defp states(region), do: region |> river() |> Map.fetch!(:reaches) |> Tuple.to_list()
  defp storage(region), do: region |> states() |> Enum.map(& &1.volume) |> Enum.sum()

  defp reach_near(region, place) do
    {index, _cell, _distance} = Terrain.nearest_channel(region.terrain, Ember.places()[place])
    Terrain.reach_of(region.terrain, index)
  end

  describe "before the source fails" do
    test "the river runs, about 1.4 m deep" do
      region = before_failure()

      for {state, reach} <- Enum.zip(states(region), Terrain.reaches(region.terrain)) do
        refute state.silent
        assert_in_delta River.depth_m(state, reach), 1.39, 0.02
      end
    end

    test "the water is warm and cools a little on its way down" do
      temps = before_failure() |> states() |> Enum.map(& &1.temp_c)

      assert hd(temps) > 39
      assert List.last(temps) > 30
      assert temps == Enum.sort(temps, :desc)
    end
  end

  describe "when the source fails" do
    setup do
      {events, region} = before_failure() |> Region.advance(4 * 60) |> Region.drain_events()
      %{events: events, region: region}
    end

    test "the miracle happens at its time, annotated on the spring", %{
      events: events,
      region: region
    } do
      assert [%Event{type: :miracle, entity: "the-source-fails", time: @failure}] =
               Enum.filter(events, &(&1.type == :miracle))

      assert %{flow_m3_s: +0.0, miracle: "the-source-fails", changed_at: @failure} =
               Region.get(region, "river-source", :spring)
    end

    test "the spring is seen to stop, once", %{events: events} do
      assert [%Event{type: :spring_stopped, time: @failure}] =
               Enum.filter(events, &(&1.type == :spring_stopped))
    end

    test "the river falls silent from upstream down: the Dry Bend before the town and the docks",
         %{events: events, region: region} do
      silences = for %Event{type: :river_silent, data: %{reach: k}, time: t} <- events, do: {k, t}

      assert Enum.map(silences, &elem(&1, 0)) ==
               Enum.to_list(0..(length(Terrain.reaches(region.terrain)) - 1))

      assert Enum.map(silences, &elem(&1, 1)) == Enum.sort(Enum.map(silences, &elem(&1, 1)))

      bend = reach_near(region, :dry_bend)
      town = reach_near(region, :town)
      docks = reach_near(region, :docks)
      assert bend < town and town < docks
      refute Enum.any?(events, &(&1.type == :river_flowing))
    end

    test "within four hours the whole river is dry", %{region: region} do
      assert Enum.all?(states(region), & &1.silent)
    end
  end

  describe "starting after the failure" do
    test "a year later the river is dry" do
      region = Ember.region({813, day: 220, hour: 4}, systems: @systems)
      assert Enum.all?(states(region), &(&1.silent and &1.volume == 0.0))
    end

    test "twenty minutes later, the top of the river is already silent and the bottom still runs" do
      region = Ember.region({812, day: 200, hour: 15, minute: 20}, systems: @systems)
      silent = Enum.map(states(region), & &1.silent)

      assert hd(silent)
      refute List.last(silent)
    end
  end

  describe "conservation" do
    property "storage changes only by inflow minus outflow minus loss, at any step length" do
      check all steps <- list_of(member_of([60, 600, 3_600]), min_length: 1, max_length: 12),
                minutes_before <- integer(0..120),
                max_runs: 25 do
        Enum.reduce(steps, before_failure(minutes_before), fn dt, region ->
          before = storage(region)
          after_step = Region.advance(region, 1, dt: dt)
          %{inflow_m3: inflow, outflow_m3: outflow, lost_m3: lost} = river(after_step).last_step

          assert_in_delta storage(after_step) - before, inflow - outflow - lost, 1.0e-6
          assert lost >= -1.0e-9
          assert lost <= 1.0e-6 * 12.0 * total_length(after_step) * dt + 1.0e-6
          assert Enum.all?(states(after_step), &(&1.volume >= 0))
          after_step
        end)
      end
    end
  end

  test "hour-long steps (history mode) still drain the river from the top down" do
    {events, _region} =
      before_failure() |> Region.advance(4, dt: 3_600) |> Region.drain_events()

    times = for %Event{type: :river_silent, time: t} <- events, do: t
    assert length(times) == 23
    assert times == Enum.sort(times)
  end

  defp total_length(region),
    do: region.terrain |> Terrain.reaches() |> Enum.map(& &1.length_m) |> Enum.sum()
end
