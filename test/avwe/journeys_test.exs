defmodule Avwe.JourneysTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Event, Intent, Region, Space, Terrain}
  alias Avwe.Test.Ember

  # Mira is played here as a session would play her, so autopilot leaves her
  # to the tests' intents; the property below lets it drive her too.
  setup_all do
    %{region: Ember.region() |> Ember.controlled(), free: Ember.region()}
  end

  defp submit(region, verb, opts) do
    ref = Keyword.get(opts, :ref, "mira-#{verb}")
    body = Keyword.get(opts, :body, "mira-vale")

    Region.submit(
      region,
      Intent.new(body, verb, opts |> Keyword.put(:ref, ref) |> Keyword.delete(:body))
    )
  end

  defp run(region, steps) do
    {events, region} = region |> Region.advance(steps) |> Region.drain_events()
    {region, events}
  end

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)

  describe "following the channel upstream" do
    setup %{region: region} do
      {region, events} = region |> submit(:follow, params: %{direction: :upstream}) |> run(45)
      %{after: region, events: events}
    end

    test "leads from the town to the river's source", %{after: region, events: events} do
      assert [%{outcome: :success, reason: :end_of_channel, params: %{direction: :upstream}}] =
               results(events)

      assert Region.get(region, "mira-vale", :position) == Terrain.source(region.terrain)
    end

    test "and Mira discovers the forgotten source on the way", %{
      region: before,
      after: region,
      events: events
    } do
      refute MapSet.member?(Region.get(before, "mira-vale", :knows), "river-source")
      assert MapSet.member?(Region.get(region, "mira-vale", :knows), "river-source")

      assert [%Event{entity: "mira-vale", data: %{place: "river-source"}}] =
               Enum.filter(events, &(&1.type == :discovered))
    end

    test "once known, she can go back to it by name", %{after: region} do
      {region, _events} = region |> submit(:go, target: "ember-reach") |> run(30)
      {_region, events} = region |> submit(:go, target: "river-source", ref: "back") |> run(30)

      assert [%{ref: "back", outcome: :success}] = results(events)
    end
  end

  test "following downstream leads out of the valley", %{region: region} do
    {region, events} = region |> submit(:follow, params: %{direction: :downstream}) |> run(30)

    assert [%{outcome: :success, reason: :end_of_channel}] = results(events)
    assert {_x, 255} = Region.get(region, "mira-vale", :position)
  end

  test "there's nothing to follow far from the channel", %{region: region} do
    {region, _events} = region |> submit(:go, target: "ashwarden-lodge") |> run(10)

    {_region, events} =
      region |> submit(:follow, params: %{direction: :upstream}, ref: "far") |> run(1)

    assert [%{ref: "far", outcome: :blocked, reason: :no_channel}] = results(events)
  end

  describe "walking in a direction" do
    test "goes that far that way", %{region: region} do
      start = Region.get(region, "mira-vale", :position)

      {region, events} =
        region |> submit(:walk, params: %{direction: "north", distance_m: 200}) |> run(5)

      assert [%{outcome: :success, reason: :walked}] = results(events)
      {x, y} = Region.get(region, "mira-vale", :position)
      assert {x, y} == {elem(start, 0), elem(start, 1) - 20}
      assert Space.meters(Space.distance(start, {x, y})) == 200
    end

    test "stops at the edge of the map", %{region: region} do
      {region, _events} =
        region |> submit(:walk, params: %{direction: "south", distance_m: 2_000}) |> run(30)

      assert {_x, 255} = Region.get(region, "mira-vale", :position)

      {_region, events} =
        region |> submit(:walk, params: %{direction: "south"}, ref: "edge") |> run(1)

      assert [%{ref: "edge", outcome: :blocked, reason: :edge}] = results(events)
    end

    test "needs a compass direction and a sensible distance", %{region: region} do
      {_region, events} =
        region
        |> submit(:walk, params: %{direction: "sideways"}, ref: "a")
        |> submit(:walk, params: %{direction: "north", distance_m: 50_000}, ref: "b")
        |> run(1)

      assert [%{outcome: :blocked, reason: :invalid}, %{outcome: :blocked, reason: :invalid}] =
               results(events)
    end
  end

  property "every intent still ends in exactly one result, with journeys and autopilot's own", %{
    free: region
  } do
    verbs =
      one_of([
        tuple(
          {constant(:follow),
           map(member_of([:upstream, :downstream, :sideways]), &[params: %{direction: &1}])}
        ),
        tuple(
          {constant(:walk),
           map(
             member_of(["north", "south-east", "up"]),
             &[params: %{direction: &1, distance_m: 300}]
           )}
        ),
        tuple(
          {constant(:go),
           map(member_of(["the-dry-bend", "river-source", "willow-docks"]), &[target: &1])}
        ),
        tuple({constant(:stop), constant([])}),
        tuple(
          {constant(:kindle), map(member_of([nil, "lodge-hearth", "nowhere"]), &[target: &1])}
        ),
        tuple(
          {constant(:douse), map(member_of([nil, "town-hearth", "the-last-coal"]), &[target: &1])}
        ),
        tuple(
          {constant(:write),
           member_of([[params: %{text: "The reeds lean north."}], [params: %{text: " "}]])}
        ),
        tuple({constant(:read), member_of([[], [params: %{last: 1}], [target: "town-hearth"]])})
      ])

    # Mira is nobody's here, so autopilot's intents (refs `auto-*`) land
    # between the batch's; every one of them that was applied has its one
    # result too, and the ones still queued at the end have none yet.
    check all batch <- list_of(verbs, min_length: 1, max_length: 6),
              later <- list_of(verbs, max_length: 3),
              max_runs: 30 do
      {region, events} =
        batch
        |> Enum.with_index()
        |> Enum.reduce(region, fn {{verb, opts}, i}, acc ->
          submit(acc, verb, [{:ref, "r#{i}"} | opts])
        end)
        |> run(60)

      {region, more} =
        later
        |> Enum.with_index()
        |> Enum.reduce(region, fn {{verb, opts}, i}, acc ->
          submit(acc, verb, [{:ref, "l#{i}"} | opts])
        end)
        |> run(60)

      events = events ++ more
      decided = for %Event{type: :decided, data: %{intent_ref: ref}} <- events, do: ref
      pending = region |> Region.pending() |> Enum.map(& &1.ref)
      running = if action = Region.get(region, "mira-vale", :action), do: [action.ref], else: []
      assert Enum.all?(decided, &String.starts_with?(&1, "auto-mira-vale-"))

      expected =
        Enum.map(0..(length(batch) - 1), &"r#{&1}") ++
          Enum.map(Enum.with_index(later), &"l#{elem(&1, 1)}") ++
          ((decided -- pending) -- running)

      assert events |> results() |> Enum.map(& &1.ref) |> Enum.sort() == Enum.sort(expected)
    end
  end
end
