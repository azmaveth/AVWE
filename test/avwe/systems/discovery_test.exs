defmodule Avwe.Systems.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Avwe.{Event, Region}
  alias Avwe.Systems.Discovery

  defp world(knows \\ []) do
    [id: {0, 0}, seed: 1, systems: [Discovery]]
    |> Region.new()
    |> Region.put_entity("edge", place: %{label: "Edge"}, position: {3, 0})
    |> Region.put_entity("just-past", place: %{label: "Just Past"}, position: {3, 1})
    |> Region.put_entity("far", place: %{label: "Far"}, position: {5, 5})
    |> Region.put_entity("here", place: %{label: "Here"}, position: {0, 0})
    |> Region.put_entity("wren", body: %{}, position: {0, 0}, knows: MapSet.new(knows))
  end

  defp step(region) do
    {events, region} = region |> Region.advance(1) |> Region.drain_events()

    {region,
     for(%Event{type: :discovered, entity: "wren", data: %{place: place}} <- events, do: place)}
  end

  test "a body learns the places within three cells, 30 m, the edge included, and no others" do
    {region, found} = step(world())

    assert found == ["edge", "here"]
    assert Region.get(region, "wren", :knows) == MapSet.new(["edge", "here"])
  end

  test "it learns a place once" do
    {region, _found} = step(world())

    assert {_region, []} = step(region)
  end

  test "it does not learn again what it knows" do
    {region, found} = step(world(["here"]))

    assert found == ["edge"]
    assert Region.get(region, "wren", :knows) == MapSet.new(["edge", "here"])
  end

  test "it learns what it comes near, wherever it goes" do
    {region, _found} = step(world())
    region = Region.put_component(region, "wren", :position, {5, 4})

    assert {_region, ["far"]} = step(region)
  end

  test "an entity that is nobody, or is nowhere, learns nothing" do
    region =
      world()
      |> Region.put_entity("no-position", body: %{}, knows: MapSet.new())
      |> Region.put_entity("no-memory", body: %{}, position: {0, 0})

    {region, _found} = step(region)

    assert Region.get(region, "no-position", :knows) == MapSet.new()
    assert Region.get(region, "no-memory", :knows) == nil
  end
end
