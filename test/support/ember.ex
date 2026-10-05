defmodule Avwe.Test.Ember do
  @moduledoc "Builds the Ember Reach's starting region, as configured, for unit tests."

  alias Avwe.{Calendar, Quire, Worldgen}
  alias Avwe.Test.Fixtures

  @systems [
    Avwe.Systems.Daylight,
    Avwe.Systems.Miracles,
    Avwe.Systems.River,
    Avwe.Systems.Movement,
    Avwe.Systems.Waiting,
    Avwe.Systems.Discovery
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
      miracles: opts[:miracles]
    )
  end

  @doc "Where the Ember Reach's pinned places are."
  def places, do: %{dry_bend: {163, 78}, town: {121, 138}, docks: {138, 162}, lodge: {94, 105}}
end
