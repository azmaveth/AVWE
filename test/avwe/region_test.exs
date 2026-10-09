defmodule Avwe.RegionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Event, Region}
  alias Avwe.Systems.Daylight
  alias Avwe.Test.Wander

  defp region(seed, systems) do
    [id: {0, 0}, seed: seed, systems: systems]
    |> Region.new()
    |> Region.put_entity("mira-vale", position: {121, 138}, repr: %{name: "Mira Vale"})
    |> Region.put_entity("heron", position: {40, 40})
    |> Region.put_entity("lodge", repr: %{name: "Ashwarden Lodge"})
  end

  describe "components" do
    test "entities are ids that appear in component maps" do
      region = region(1, [])

      assert Region.get(region, "mira-vale", :position) == {121, 138}

      assert Region.entity(region, "mira-vale") == %{
               position: {121, 138},
               repr: %{name: "Mira Vale"}
             }

      assert Region.entity(region, "nobody") == %{}
    end

    test "with_components/2 returns sorted ids that have every component" do
      region = region(1, [])

      assert Region.with_components(region, [:position]) == ["heron", "mira-vale"]
      assert Region.with_components(region, [:position, :repr]) == ["mira-vale"]
      assert Region.with_components(region, [:missing]) == []
    end

    test "delete_entity/2 removes every component" do
      region = region(1, []) |> Region.delete_entity("mira-vale")

      assert Region.entity(region, "mira-vale") == %{}
      assert Region.with_components(region, [:position]) == ["heron"]
    end
  end

  describe "advance/3" do
    test "moves time forward by dt per step" do
      region = region(1, []) |> Region.advance(3)
      assert {region.step, region.time} == {3, 180}

      region = Region.advance(region, 2, dt: 3_600)
      assert {region.step, region.time} == {5, 180 + 7_200}
    end

    test "collects events stamped with the region id, oldest first" do
      region =
        [id: {0, 0}, seed: 1, systems: [Daylight], time: Avwe.Calendar.at(813, hour: 4)]
        |> Region.new()
        |> Region.advance(16 * 60)

      {events, drained} = Region.drain_events(region)

      assert [%Event{type: :sunrise, region: {0, 0}}, %Event{type: :sunset, region: {0, 0}}] =
               events

      assert drained.outbox == []
    end
  end

  defmodule Ticker do
    @moduledoc false
    @behaviour Avwe.System

    # Emits one event a step, then a second that records how many events
    # `Region.step_events/2` showed it.
    @impl Avwe.System
    def run(region, tick) do
      tock = Event.new(:tock, data: %{step: tick.step})
      seen = Region.step_events(%{region | outbox: [tock | region.outbox]}, tick)
      {region, [tock, Event.new(:seen, data: %{step: tick.step, seen: length(seen)})]}
    end
  end

  describe "step_events/2" do
    test "shows only the step's own events however long the outbox has gone undrained" do
      region = %{region(1, [Ticker]) | outbox: [Event.new(:old), Event.new(:older)]}
      {events, _drained} = region |> Region.advance(5) |> Region.drain_events()

      assert [:older, :old | rest] = Enum.map(events, & &1.type)
      assert rest == List.flatten(List.duplicate([:tock, :seen], 5))
      assert for(%Event{type: :seen, data: data} <- events, do: data.seen) == [1, 1, 1, 1, 1]
      assert for(%Event{type: :tock, data: data} <- events, do: data.step) == [0, 1, 2, 3, 4]
    end
  end

  describe "near/4" do
    defp placed(cells) do
      cells
      |> Enum.with_index()
      |> Enum.reduce(Region.new(id: {0, 0}, seed: 1), fn {cell, n}, acc ->
        Region.put_entity(acc, "e#{n}", position: cell, tag: n)
      end)
    end

    test "is the ids within the radius in metres, sorted, the edge included" do
      region = placed([{10, 10}, {13, 10}, {10, 14}, {14, 13}, {40, 40}])

      # Cells are 10 m: three cells is 30 m, and {14, 13} is five cells away.
      assert Region.near(region, {10, 10}, 30) == ["e0", "e1"]
      assert Region.near(region, {10, 10}, 29.9) == ["e0"]
      assert Region.near(region, {10, 10}, 50) == ["e0", "e1", "e2", "e3"]
      assert Region.near(region, {10, 10}, 0) == ["e0"]
    end

    test "asks for the components it is given, and for a position whatever it is asked" do
      region =
        placed([{1, 1}, {2, 2}])
        |> Region.put_component("e0", :place, %{label: "Here"})
        |> Region.put_entity("nowhere", place: %{label: "Nowhere"})

      assert Region.near(region, {1, 1}, 100, [:place]) == ["e0"]
      assert Region.near(region, {1, 1}, 100, [:place, :position]) == ["e0"]
      assert Region.near(region, {1, 1}, 100) == ["e0", "e1"]
      assert Region.near(region, {1, 1}, 100, [:missing]) == []
    end

    property "is what a scan of every entity gives" do
      check all cells <- list_of({integer(0..30), integer(0..30)}, max_length: 25),
                center <- {integer(0..30), integer(0..30)},
                radius <- integer(0..400) do
        region = placed(cells)

        expected =
          for id <- Region.with_components(region, [:position]),
              Avwe.Space.distance(Region.get(region, id, :position), center) *
                Avwe.Space.cell_size_m() <= radius,
              do: id

        assert Region.near(region, center, radius) == expected
      end
    end
  end

  describe "determinism" do
    property "the same seed and steps always give the same state" do
      check all seed <- integer(), steps <- integer(1..30) do
        assert Region.state_hash(Region.advance(region(seed, [Wander]), steps)) ==
                 Region.state_hash(Region.advance(region(seed, [Wander]), steps))
      end
    end

    property "advancing many steps at once equals advancing one at a time" do
      check all seed <- integer(), steps <- integer(1..30) do
        start = region(seed, [Wander])
        one_at_a_time = Enum.reduce(1..steps, start, fn _n, acc -> Region.advance(acc, 1) end)

        assert Region.state_hash(Region.advance(start, steps)) == Region.state_hash(one_at_a_time)
      end
    end

    test "different seeds give different worlds" do
      refute Region.state_hash(Region.advance(region(1, [Wander]), 20)) ==
               Region.state_hash(Region.advance(region(2, [Wander]), 20))
    end

    test "adding a system doesn't change another system's randomness" do
      alone = region(7, [Wander]) |> Region.advance(50)
      with_daylight = region(7, [Daylight, Wander]) |> Region.advance(50)

      assert alone.components.position == with_daylight.components.position
    end

    test "the outbox doesn't affect the state hash" do
      region = region(1, [Daylight]) |> Region.advance(10)

      assert Region.state_hash(%{region | outbox: [Event.new(:noise)]}) ==
               Region.state_hash(%{region | outbox: []})
    end
  end
end
