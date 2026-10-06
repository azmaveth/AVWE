defmodule Avwe.Systems.MemoryTest do
  @moduledoc """
  Body memory and "While you were away". Lantern Hollow at noon, where Wren
  and Tamsin stand on Hollow Green, Wren with a notebook; and the Ember
  Reach, for replay with autopilot and a fire.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Intent, Perception, Prose, Quire, Region, Worldgen}
  alias Avwe.Systems.{Daylight, Memory, Movement, Waiting}
  alias Avwe.Test.{Ember, Fixtures}

  @systems [Daylight, Movement, Waiting, Memory]

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  defp hollow(world, at \\ [hour: 12]) do
    world
    |> Quire.Seed.region(id: {0, 0}, seed: 1, time: Calendar.at(1, at), systems: @systems)
    |> Worldgen.add_characters(
      wren: [carries: [[id: "wren-notebook", kind: :notebook, name: "field notebook"]]]
    )
    |> Region.prepare()
  end

  defp submit(region, body, verb, opts) do
    ref = Keyword.get(opts, :ref, "#{body}-#{verb}-#{region.next_seq}")
    Region.submit(region, Intent.new(body, verb, Keyword.put(opts, :ref, ref)))
  end

  defp say(region, body, text), do: submit(region, body, :say, params: %{text: text})

  defp run(region, steps \\ 1) do
    {_events, region} = region |> Region.advance(steps) |> Region.drain_events()
    region
  end

  defp entries(region, body), do: (Region.get(region, body, :memory) || %{entries: []}).entries
  defp summaries(region, body), do: region |> entries(body) |> Enum.map(& &1.summary)
  defp view(region), do: region |> Region.view() |> Map.put(:terrain, region.terrain)
  defp away(region, body), do: region |> view() |> Perception.away(body) |> Enum.map(& &1.summary)

  describe "what a body remembers" do
    test "what it sensed and the results that say something, newest first", %{world: world} do
      region =
        world
        |> hollow()
        |> say("tamsin", "The pond is low.")
        |> run()
        |> submit("wren", :go, target: "mill-pond")
        |> run(10)

      assert [
               %{type: :action_result, summary: "You arrive at Mill Pond."},
               %{type: :speech, summary: ~s(Tamsin says, "The pond is low."), time: said}
             ] = entries(region, "wren")

      assert said == Calendar.at(1, hour: 12, minute: 1)

      assert summaries(region, "tamsin") == [
               "Wren arrives at Mill Pond.",
               "Wren leaves, heading toward Mill Pond.",
               ~s(You say, "The pond is low.")
             ]
    end

    test "not its own progress, the sun's rising and setting, or a notebook's reading", %{
      world: world
    } do
      region =
        world
        |> hollow(hour: 5, minute: 50)
        |> submit("wren", :write, params: %{text: "dawn soon"})
        |> run()
        |> submit("wren", :read, [])
        |> submit("wren", :wait, params: %{for: 20 * 60})
        |> run(25)

      assert summaries(region, "wren") == [
               "You finish waiting.",
               "You write in your field notebook."
             ]

      refute Enum.any?(
               entries(region, "wren"),
               &(&1.type in [:sunrise, :sunset, :action_started])
             )
    end

    test "keeps the newest #{Memory.keep()}", %{world: world} do
      region =
        Enum.reduce(1..60, hollow(world), fn n, acc -> acc |> say("tamsin", "#{n}") |> run() end)

      wren = summaries(region, "wren")
      assert length(wren) == Memory.keep()
      assert hd(wren) == ~s(Tamsin says, "60")
      assert List.last(wren) == ~s(Tamsin says, "11")
    end

    test "its own fire, lit at the moment of the intent" do
      region =
        Ember.region({813, day: 220, hour: 12})
        |> Ember.controlled()
        |> submit("mira-vale", :kindle, target: "town-hearth")
        |> run()

      assert "You light the kiln-house hearth." in summaries(region, "mira-vale")
    end

    test "what it smelled: Memory runs after Smoke, so the smoke a step raises is remembered" do
      region =
        Ember.region({813, day: 220, hour: 12})
        |> Ember.controlled()
        |> submit("mira-vale", :kindle, target: "town-hearth")
        |> run(10)

      assert Enum.any?(entries(region, "mira-vale"), &(&1.type == :smoke_smelled))
      assert Enum.any?(summaries(region, "mira-vale"), &(&1 =~ ~r/^You smell woodsmoke/))
    end
  end

  describe "replay" do
    test "regenerates the same memories, whether stepped one at a time or at once" do
      start =
        Ember.region()
        |> submit("mira-vale", :say, params: %{text: "Good morning."}, ref: "hello")

      one_by_one = Enum.reduce(1..150, start, fn _n, acc -> run(acc) end)
      at_once = Region.advance(start, 150)

      assert Region.state_hash(one_by_one) == Region.state_hash(at_once)
      assert entries(one_by_one, "mira-vale") == entries(at_once, "mira-vale")
      assert "You arrive at The Dry Bend." in summaries(at_once, "mira-vale")
    end
  end

  describe "away" do
    test "is everything remembered when the body was never held, oldest first, at most 12", %{
      world: world
    } do
      region =
        Enum.reduce(1..15, hollow(world), fn n, acc -> acc |> say("tamsin", "#{n}") |> run() end)

      assert away(region, "wren") == Enum.map(4..15, &~s(Tamsin says, "#{&1}"))
    end

    test "is what happened since the body was released, and nothing while held", %{world: world} do
      region =
        world
        |> hollow()
        |> submit("wren", :control, controller: :human)
        |> run()
        |> say("tamsin", "before")
        |> run()

      assert away(region, "wren") == []
      assert ~s(Tamsin says, "before") in summaries(region, "wren")

      region = region |> submit("wren", :release, []) |> run() |> say("tamsin", "after") |> run()

      assert away(region, "wren") == [
               "You let your routine carry you.",
               ~s(Tamsin says, "after")
             ]
    end

    test "is told first in a look, with the day when it was not today", %{world: world} do
      region =
        world
        |> hollow(hour: 23, minute: 58)
        |> say("tamsin", "Late.")
        |> run(3)
        |> say("tamsin", "Past midnight.")
        |> run()

      look = Perception.look(view(region), "wren")
      assert [_late, _past] = look.away

      assert [
               _clock,
               "While you were away:",
               late,
               past,
               "You are Wren, at Hollow Green." | _rest
             ] =
               String.split(Prose.look(look), "\n")

      assert late == ~s(  day 1, 23:59 Tamsin says, "Late.")
      assert past == ~s(  00:02 Tamsin says, "Past midnight.")
    end
  end
end
