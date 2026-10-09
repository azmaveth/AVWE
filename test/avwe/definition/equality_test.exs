defmodule Avwe.Definition.EqualityTest do
  @moduledoc """
  The two ways to build the Ember Reach must build the same world: from Quire
  and the world's settings (`Avwe.Worldgen.region/2`, the way it was always
  built), and from its definition (`Avwe.Definition.region/2`, the way it is
  run). Equal means equal to the last term: the hash of the whole region.
  """

  use ExUnit.Case, async: true

  alias Avwe.Region
  alias Avwe.Systems.{Fire, Miracles}
  alias Avwe.Test.Ember

  @times [
    {813, day: 220, hour: 4},
    {812, day: 199, hour: 14},
    {812, day: 201, hour: 0},
    {0, []}
  ]

  # Where two regions differ, by field and by component: what an unequal hash
  # cannot say.
  defp differences(old, new) do
    fields =
      for key <- Map.keys(old) -- [:__struct__, :components],
          Map.get(old, key) != Map.get(new, key),
          do: key

    components =
      for name <- Enum.uniq(Map.keys(old.components) ++ Map.keys(new.components)),
          Map.get(old.components, name) != Map.get(new.components, name),
          do: {:component, name}

    fields ++ components
  end

  defp assert_equal(old, new) do
    assert differences(old, new) == []
    assert Region.state_hash(old) == Region.state_hash(new)
  end

  for at <- @times do
    test "the region at #{inspect(at)} is the same either way" do
      assert_equal(
        Ember.region(unquote(Macro.escape(at))),
        Ember.region_from_definition(unquote(Macro.escape(at)))
      )
    end
  end

  test "the same, with other systems running" do
    systems = [systems: [Miracles, Fire]]

    assert_equal(
      Ember.region({813, day: 220, hour: 4}, systems),
      Ember.region_from_definition({813, day: 220, hour: 4}, systems)
    )
  end

  test "the same, with the settings changed the same way" do
    for overrides <- [
          [miracles: []],
          [hearths: []],
          [characters: []],
          [terrain: nil],
          [climate: [wind: [from: "north", m_s: 9.0]]]
        ] do
      at = {813, day: 220, hour: 4}
      assert_equal(Ember.region(at, overrides), Ember.region_from_definition(at, overrides))
    end
  end

  test "and the same a day later: what one does, the other does" do
    at = {812, day: 199, hour: 14}
    old = Ember.region(at) |> Region.advance(24 * 60)
    new = Ember.region_from_definition(at) |> Region.advance(24 * 60)

    assert_equal(old, new)
  end

  test "the world the definition builds is not the world with the miracle left out" do
    at = {813, day: 220, hour: 4}

    refute Region.state_hash(Ember.region_from_definition(at)) ==
             Region.state_hash(Ember.region_from_definition(at, miracles: []))
  end
end
