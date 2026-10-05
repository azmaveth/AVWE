defmodule Avwe.Worldgen do
  @moduledoc """
  Builds a world's starting region from Quire and AVWE's own settings for that
  world. Pure.

  Quire supplies the places and characters (`Avwe.Quire.Seed`). AVWE's world
  settings add:

    * `:terrain` - the spec for `Avwe.Terrain.Generator`. If it has a river,
      the river's source becomes a place (unpinned, so nobody knows it) with a
      spring, and the river becomes an entity whose reaches the river system
      simulates.
    * `:miracles` - miracle events, each a keyword list with `:id`, `:at`
      (a world time, or `{year, opts}`), `:target`, `:component`, `:set`,
      `:cause` and `:note`.

  Finally each system prepares the region for its starting time
  (`Avwe.Region.prepare/1`).
  """

  alias Avwe.{Calendar, Quire, Region, Terrain}
  alias Avwe.Systems.River
  alias Avwe.Terrain.Generator

  @grid 256

  @doc """
  Builds the region. Options: those of `Avwe.Region.new/1`, plus `:terrain`
  and `:miracles` as above.
  """
  @spec region(Quire.World.t(), keyword()) :: Region.t()
  def region(quire_world, opts) do
    quire_world
    |> Quire.Seed.region(Keyword.take(opts, [:id, :seed, :time, :dt, :systems]) ++ [grid: @grid])
    |> add_terrain(Keyword.get(opts, :terrain))
    |> add_miracles(Keyword.get(opts, :miracles, []))
    |> Region.prepare()
  end

  defp add_terrain(region, nil), do: region

  defp add_terrain(region, spec) do
    places =
      Map.new(
        Region.with_components(region, [:place, :position]),
        &{&1, Region.get(region, &1, :position)}
      )

    terrain = Generator.generate(spec, places, seed: region.seed, width: @grid, height: @grid)

    region
    |> Map.put(:terrain, terrain)
    |> add_river(terrain, Keyword.get(spec, :river))
  end

  defp add_river(region, _terrain, nil), do: region

  defp add_river(region, terrain, river) do
    source = Keyword.fetch!(river, :source)
    source_id = Keyword.fetch!(source, :id)
    flow = Keyword.fetch!(river, :flow_m3_s)

    region
    |> Region.put_entity(source_id, %{
      place: %{label: Keyword.fetch!(source, :name)},
      position: Terrain.source(terrain),
      repr: %{name: Keyword.fetch!(source, :name), description: Keyword.get(source, :description)},
      spring: %{natural_m3_s: flow, flow_m3_s: flow, temp_c: Keyword.fetch!(river, :water_c)}
    })
    |> Region.put_entity(River.id(), %{
      repr: %{name: Keyword.fetch!(river, :name), description: nil},
      river: %{
        source: source_id,
        reaches: {},
        inflow: flow,
        last_step: %{inflow_m3: 0.0, outflow_m3: 0.0, lost_m3: 0.0}
      }
    })
  end

  defp add_miracles(region, miracles) do
    Enum.reduce(miracles, region, fn miracle, acc ->
      Region.put_entity(acc, Keyword.fetch!(miracle, :id), %{
        miracle: %{
          kind: :event,
          at: time(Keyword.fetch!(miracle, :at)),
          target: Keyword.fetch!(miracle, :target),
          component: Keyword.fetch!(miracle, :component),
          set: Keyword.fetch!(miracle, :set),
          cause: Keyword.get(miracle, :cause, :unknown),
          note: Keyword.get(miracle, :note),
          applied_at: nil
        }
      })
    end)
  end

  defp time({year, opts}), do: Calendar.at(year, opts)
  defp time(time) when is_integer(time), do: time
end
