defmodule Avwe.ActionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Calendar, Event, Intent, Quire, Region, Worldgen}
  alias Avwe.Systems.{Daylight, Movement, Waiting}
  alias Avwe.Test.Fixtures

  @systems [Daylight, Movement, Waiting]

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  # Wren carries a notebook, so writing and reading can succeed.
  defp hollow(world, hour \\ 12) do
    world
    |> Quire.Seed.region(id: {0, 0}, seed: 1, time: Calendar.at(1, hour: hour), systems: @systems)
    |> Worldgen.add_characters(
      wren: [carries: [[id: "wren-notebook", kind: :notebook, name: "notebook"]]]
    )
    |> Region.prepare()
  end

  defp submit(region, body, verb, opts) do
    ref = Keyword.get(opts, :ref, "#{body}-#{verb}")
    Region.submit(region, Intent.new(body, verb, Keyword.put(opts, :ref, ref)))
  end

  defp run(region, steps) do
    {events, region} = region |> Region.advance(steps) |> Region.drain_events()
    {region, events}
  end

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)

  describe "go" do
    test "walks to a known place, reporting each quarter and arrival", %{world: world} do
      {region, events} =
        world |> hollow() |> submit("odo", :go, target: "hollow-green") |> run(25)

      assert [%{ref: "odo-go", outcome: :success, reason: :arrived}] = results(events)

      assert for(%Event{type: :action_progress, data: d} <- events, do: d.progress) ==
               [0.25, 0.5, 0.75]

      assert Region.get(region, "odo", :position) == Region.get(region, "hollow-green", :position)
      assert Region.get(region, "odo", :action) == nil
      assert Enum.any?(events, &match?(%Event{type: :departed, entity: "odo"}, &1))

      assert Enum.any?(
               events,
               &match?(%Event{type: :arrived, data: %{place: "hollow-green"}}, &1)
             )
    end

    test "is blocked for a place the body doesn't know", %{world: world} do
      {_region, events} = world |> hollow() |> submit("wren", :go, target: "atlantis") |> run(1)
      assert [%{outcome: :blocked, reason: :unknown_place}] = results(events)
    end

    test "succeeds at once when already there", %{world: world} do
      {_region, events} =
        world |> hollow() |> submit("wren", :go, target: "hollow-green") |> run(1)

      assert [%{outcome: :success, reason: :already_there}] = results(events)
    end

    test "a new action replaces the old one, which is interrupted", %{world: world} do
      {_region, events} =
        world
        |> hollow()
        |> submit("odo", :go, target: "hollow-green", ref: "first")
        |> run(2)
        |> elem(0)
        |> submit("odo", :go, target: "mill-pond", ref: "second")
        |> run(1)

      assert [%{ref: "first", outcome: :interrupted, reason: :replaced}] = results(events)
    end
  end

  describe "stop" do
    test "interrupts the current action", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> submit("odo", :go, target: "hollow-green")
        |> run(2)
        |> elem(0)
        |> submit("odo", :stop, [])
        |> run(1)

      assert [
               %{ref: "odo-go", outcome: :interrupted, reason: :stopped},
               %{ref: "odo-stop", outcome: :success}
             ] = results(events)

      assert Region.get(region, "odo", :action) == nil
    end

    test "with nothing to stop still succeeds", %{world: world} do
      {_region, events} = world |> hollow() |> submit("wren", :stop, []) |> run(1)
      assert [%{outcome: :success, reason: :idle}] = results(events)
    end
  end

  describe "wait" do
    test "for a duration finishes when the time has passed", %{world: world} do
      region = world |> hollow() |> submit("wren", :wait, params: %{for: 30 * 60})

      {region, events} = run(region, 29)
      assert results(events) == []

      {_region, events} = run(region, 1)
      assert [%{outcome: :success}] = results(events)
    end

    test "is stamped as begun at the start of its step, so it shows its whole length", %{
      world: world
    } do
      region = world |> hollow() |> submit("wren", :wait, params: %{for: 5 * 60})
      {_region, events} = run(region, 5)

      noon = Calendar.at(1, hour: 12)
      assert [%Event{time: ^noon}] = Enum.filter(events, &(&1.type == :action_started))

      assert [%Event{time: finished}] = Enum.filter(events, &(&1.type == :action_result))
      assert finished - noon == 5 * 60
    end

    test "until dawn finishes at sunrise", %{world: world} do
      {_region, events} =
        world |> hollow(4) |> submit("wren", :wait, params: %{until: :dawn}) |> run(150)

      [result] = for %Event{type: :action_result} = event <- events, do: event
      assert result.time == Calendar.at(1, hour: 6)
    end

    test "with nonsense is blocked", %{world: world} do
      {_region, events} =
        world |> hollow() |> submit("wren", :wait, params: %{until: :tuesday}) |> run(1)

      assert [%{outcome: :blocked, reason: :invalid}] = results(events)
    end
  end

  describe "say" do
    test "emits speech from where the body stands", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> submit("wren", :say, params: %{text: "  hello  ", volume: :shout})
        |> run(1)

      assert [%Event{type: :speech, entity: "wren", data: speech}] =
               Enum.filter(events, &(&1.type == :speech))

      assert speech == %{
               text: "hello",
               volume: :shout,
               position: Region.get(region, "wren", :position)
             }

      assert [%{outcome: :success, params: %{text: "hello", volume: :shout}}] = results(events)
    end

    test "is one line of plain text: escape sequences go, breaks become spaces, the rest go", %{
      world: world
    } do
      forged = "Hi.\n12:00 Tamsin says, \"Run.\"\r\n\e[2J\e]0;title\a\e[31mBye.\a"

      {_region, events} =
        world
        |> hollow()
        |> submit("wren", :say, params: %{text: forged}, ref: "forged")
        |> submit("wren", :say, params: %{text: "\n\e[31m\t"}, ref: "nothing left")
        |> run(1)

      assert [%Event{data: %{text: ~s(Hi. 12:00 Tamsin says, "Run." Bye.)}}] =
               Enum.filter(events, &(&1.type == :speech))

      assert [%{ref: "forged", outcome: :success}, %{ref: "nothing left", outcome: :blocked}] =
               results(events)
    end

    test "with nothing to say, or an unknown volume, is blocked", %{world: world} do
      {_region, events} =
        world
        |> hollow()
        |> submit("wren", :say, params: %{text: "   "}, ref: "empty")
        |> submit("wren", :say, params: %{text: "hi", volume: :sing}, ref: "sing")
        |> run(1)

      assert [%{outcome: :blocked}, %{outcome: :blocked}] = results(events)
    end
  end

  describe "control" do
    defp holder(region, body), do: Region.get(region, body, :control).holder

    test "is taken and released, and written on the body", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> submit("wren", :control, controller: :arbor, ref: "take")
        |> run(1)

      assert [%{ref: "take", outcome: :success, reason: nil}] = results(events)

      assert [%Event{type: :control_taken, entity: "wren", data: %{controller: :arbor}}] =
               Enum.filter(events, &(&1.type == :control_taken))

      assert holder(region, "wren") == :arbor
      assert Region.get(region, "wren", :control).since == region.time - 60

      {region, events} = region |> submit("wren", :release, ref: "give") |> run(1)
      assert [%{ref: "give", outcome: :success, reason: nil}] = results(events)

      assert [%Event{type: :control_released, data: %{controller: :arbor}}] =
               Enum.filter(events, &(&1.type == :control_released))

      assert holder(region, "wren") == nil
    end

    test "taking what one holds, or releasing what nobody holds, still succeeds", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> submit("wren", :control, controller: :human, ref: "once")
        |> submit("wren", :control, controller: :human, ref: "twice")
        |> submit("pell", :release, ref: "nobody")
        |> run(1)

      assert [
               %{ref: "nobody", outcome: :success, reason: :already},
               %{ref: "once", outcome: :success, reason: nil},
               %{ref: "twice", outcome: :success, reason: :already}
             ] = results(events)

      assert Enum.count(events, &(&1.type == :control_taken)) == 1
      assert holder(region, "wren") == :human
    end

    test "without a controller there is nobody to take it", %{world: world} do
      {_region, events} = world |> hollow() |> submit("wren", :control, []) |> run(1)
      assert [%{outcome: :blocked, reason: :invalid}] = results(events)
    end
  end

  test "an unknown verb is blocked", %{world: world} do
    {_region, events} = world |> hollow() |> submit("wren", :fly, []) |> run(1)
    assert [%{outcome: :blocked, reason: :unknown_verb}] = results(events)
  end

  test "a body that doesn't exist can't act", %{world: world} do
    {_region, events} =
      world |> hollow() |> submit("ghost", :say, params: %{text: "boo"}) |> run(1)

    assert [%{outcome: :blocked, reason: :no_such_body}] = results(events)
  end

  describe "every intent" do
    defp intent_gen do
      bodies = member_of(["wren", "tamsin", "pell", "odo", "ghost"])

      verb_and_opts =
        one_of([
          tuple(
            {constant(:go),
             map(member_of(["hollow-green", "mill-pond", "far-tower", "nowhere"]), &[target: &1])}
          ),
          tuple(
            {constant(:wait),
             map(
               member_of([%{for: 600}, %{for: 3_600}, %{until: :dusk}, %{for: -1}]),
               &[params: &1]
             )}
          ),
          tuple(
            {constant(:say),
             map(
               member_of([%{text: "hi"}, %{text: ""}, %{text: "hey", volume: :shout}]),
               &[params: &1]
             )}
          ),
          tuple({constant(:stop), constant([])}),
          tuple({constant(:kindle), map(member_of([nil, "mill-pond"]), &[target: &1])}),
          tuple({constant(:douse), map(member_of([nil, "mill-pond"]), &[target: &1])}),
          tuple(
            {constant(:write),
             map(
               member_of([
                 [params: %{text: "a note"}],
                 [params: %{text: ""}],
                 [params: %{text: "x"}, target: "wren-notebook"],
                 [params: %{text: "x"}, target: "mill-pond"]
               ]),
               & &1
             )}
          ),
          tuple(
            {constant(:read),
             member_of([[], [params: %{last: 3}], [params: %{last: 0}], [target: "nowhere"]])}
          ),
          tuple({constant(:control), map(member_of([:human, :arbor, nil]), &[controller: &1])}),
          tuple({constant(:release), constant([])}),
          tuple({constant(:juggle), constant([])})
        ])

      tuple({bodies, verb_and_opts})
    end

    property "ends in exactly one result", %{world: world} do
      check all first <- list_of(intent_gen(), max_length: 8),
                later <- list_of(intent_gen(), max_length: 8) do
        submit_all = fn region, intents, prefix ->
          intents
          |> Enum.with_index()
          |> Enum.reduce(region, fn {{body, {verb, opts}}, i}, acc ->
            submit(acc, body, verb, [{:ref, "#{prefix}#{i}"} | opts])
          end)
        end

        {region, early} = world |> hollow(14) |> submit_all.(first, "a") |> run(3)
        {_region, rest} = region |> submit_all.(later, "b") |> run(8 * 60)

        refs = (early ++ rest) |> results() |> Enum.map(& &1.ref)

        expected =
          Enum.map(Enum.with_index(first), &"a#{elem(&1, 1)}") ++
            Enum.map(Enum.with_index(later), &"b#{elem(&1, 1)}")

        assert Enum.sort(refs) == Enum.sort(expected)
      end
    end
  end
end
