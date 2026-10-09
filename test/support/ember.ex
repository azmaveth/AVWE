defmodule Avwe.Test.Ember do
  @moduledoc "Builds the Ember Reach's starting region, as configured, for unit tests."

  alias Avwe.{Calendar, Definition, Quire, Region, Worldgen}
  alias Avwe.Test.Fixtures

  @systems [
    Avwe.Systems.Daylight,
    Avwe.Systems.Miracles,
    Avwe.Systems.Weather,
    Avwe.Systems.River,
    Avwe.Systems.Fire,
    Avwe.Systems.Heat,
    Avwe.Systems.Movement,
    Avwe.Systems.Waiting,
    Avwe.Systems.Discovery,
    Avwe.Systems.Autopilot,
    Avwe.Systems.Smoke,
    Avwe.Systems.Memory
  ]

  @doc "The Ember Reach's region at a time given as `{year, opts}`."
  def region(at \\ {813, day: 220, hour: 4}, overrides \\ []) do
    {:ok, quire} = Quire.load(Fixtures.ember_reach())
    opts = Fixtures.ember_reach_opts(overrides)
    {year, day_opts} = at

    Worldgen.region(quire,
      id: {0, 0},
      seed: opts[:seed],
      time: Calendar.at(year, day_opts),
      systems: Keyword.get(overrides, :systems, @systems),
      terrain: opts[:terrain],
      hearths: opts[:hearths],
      miracles: opts[:miracles],
      climate: opts[:climate],
      characters: opts[:characters]
    )
  end

  @doc """
  The same region, built the other way: from the fixture's world definition
  (`Fixtures.ember_reach_definition/1`) and not from Quire and settings. The
  two must be equal in every respect (`test/avwe/definition/equality_test.exs`).
  `overrides` are those of `region/2`, and change the definition as they would
  change the settings.
  """
  def region_from_definition(at \\ {813, day: 220, hour: 4}, overrides \\ []) do
    definition =
      Fixtures.ember_reach_definition([start: at] ++ Keyword.delete(overrides, :systems))

    Definition.region(definition, id: {0, 0}, systems: Keyword.get(overrides, :systems, @systems))
  end

  @doc """
  The region with `body` under a controller, as it is when a session plays
  it: autopilot leaves the body alone, so a test's own intents are the only
  ones it acts on.
  """
  def controlled(region, body \\ "mira-vale", controller \\ :human) do
    Region.put_component(region, body, :control, %{holder: controller, since: region.time})
  end

  @doc "Where the Ember Reach's pinned places are."
  def places, do: %{dry_bend: {163, 78}, town: {121, 138}, docks: {138, 162}, lodge: {94, 105}}
end
