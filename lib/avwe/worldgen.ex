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
    * `:hearths` - fires people can light (`Avwe.Systems.Fire`), each a
      keyword list with `:id`, `:at` (a place id), `:name`, `:fuel_kg` (at
      least zero: an empty hearth is allowed) and `:power_w` (above zero: the
      fire system divides by it). A bad value raises `ArgumentError` here,
      at build time, rather than in a step.
    * `:miracles` - miracle events, each a keyword list with `:id`, `:at`
      (a world time, or `{year, opts}`), `:target`, `:component`, `:set`,
      `:cause` and `:note`; or standing miracles (`kind: :standing`), hearths
      that burn without fuel, with `:id`, `:at` (a place id), `:heat_w`
      (above zero), `:breaks`, `:cause` and `:note`. A standing miracle takes
      its name and description from the Quire article with its id when there
      is one, else from `:name` and `:description`. It never smokes.
    * `:climate` - `wind: [from: direction, m_s: speed]`, the region's
      constant wind (`env.wind`). `from` must be one of the eight compass
      directions (`Avwe.Space.directions/0`) and `m_s` at least zero; a bad
      value raises `ArgumentError` here, as a bad hearth does, rather than
      in the smoke system's first step. Default: 2 m/s from the south-west.

  Finally each system prepares the region for its starting time
  (`Avwe.Region.prepare/1`).
  """

  alias Avwe.{Calendar, Quire, Region, Space, Terrain}
  alias Avwe.Systems.{Fire, River}
  alias Avwe.Terrain.Generator

  @grid 256
  @default_wind %{from: "south-west", m_s: 2.0}

  @doc """
  Builds the region. Options: those of `Avwe.Region.new/1`, plus `:terrain`,
  `:hearths`, `:miracles` and `:climate` as above.
  """
  @spec region(Quire.World.t(), keyword()) :: Region.t()
  def region(quire_world, opts) do
    quire_world
    |> Quire.Seed.region(Keyword.take(opts, [:id, :seed, :time, :dt, :systems]) ++ [grid: @grid])
    |> add_terrain(Keyword.get(opts, :terrain))
    |> add_hearths(Keyword.get(opts, :hearths) || [])
    |> add_miracles(Keyword.get(opts, :miracles) || [], quire_world)
    |> add_climate(Keyword.get(opts, :climate))
    |> Region.prepare()
  end

  defp add_climate(region, climate) do
    wind = climate |> List.wrap() |> Keyword.get(:wind, [])

    Region.put_env(region, :wind, %{
      from: direction!(Keyword.get(wind, :from, @default_wind.from)),
      m_s: non_negative!(Keyword.put_new(wind, :m_s, @default_wind.m_s), :m_s, nil, "wind")
    })
  end

  # The wind's direction, checked where a bad one is easiest to explain: the
  # smoke system would fail to drift its first puff.
  defp direction!(from) do
    if from in Space.directions(),
      do: from,
      else:
        raise(
          ArgumentError,
          "wind: from must be one of #{Enum.join(Space.directions(), ", ")}, got #{inspect(from)}"
        )
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

  defp add_hearths(region, hearths) do
    Enum.reduce(hearths, region, fn hearth, acc ->
      id = Keyword.fetch!(hearth, :id)

      Region.put_entity(acc, id, %{
        hearth: %{
          fuel_kg: non_negative!(hearth, :fuel_kg, id),
          burning: false,
          lit_at: nil,
          out_at: nil,
          power_w: positive!(hearth, :power_w, id),
          low_kg: 1.0,
          last_step: Fire.zero_step()
        },
        position: position_of(acc, Keyword.fetch!(hearth, :at)),
        repr: %{name: Keyword.fetch!(hearth, :name), description: nil}
      })
    end)
  end

  # A hearth's numbers, checked where a bad one is easiest to explain: the
  # fire system divides by `power_w`, and negative fuel is not a hearth.
  # `what` names the thing being built, so the message blames what the config
  # calls it; `id` is left out for the one wind.
  defp positive!(config, key, id, what \\ "hearth") do
    value = Keyword.fetch!(config, key) * 1.0

    if value > 0,
      do: value,
      else: raise(ArgumentError, "#{blame(what, id)}: #{key} must be above 0, got #{value}")
  end

  defp non_negative!(config, key, id, what \\ "hearth") do
    value = Keyword.fetch!(config, key) * 1.0

    if value >= 0,
      do: value,
      else: raise(ArgumentError, "#{blame(what, id)}: #{key} must be at least 0, got #{value}")
  end

  defp blame(what, nil), do: what
  defp blame(what, id), do: "#{what} #{inspect(id)}"

  defp add_miracles(region, miracles, quire_world) do
    Enum.reduce(miracles, region, fn miracle, acc ->
      id = Keyword.fetch!(miracle, :id)

      case Keyword.get(miracle, :kind, :event) do
        :standing -> Region.put_entity(acc, id, standing_miracle(acc, miracle, quire_world))
        :event -> Region.put_entity(acc, id, %{miracle: event_miracle(miracle)})
      end
    end)
  end

  defp event_miracle(miracle) do
    %{
      kind: :event,
      at: time(Keyword.fetch!(miracle, :at)),
      target: Keyword.fetch!(miracle, :target),
      component: Keyword.fetch!(miracle, :component),
      set: Keyword.fetch!(miracle, :set),
      cause: Keyword.get(miracle, :cause, :unknown),
      note: Keyword.get(miracle, :note),
      applied_at: nil
    }
  end

  # A standing miracle is a hearth that burns without fuel, already lit. It
  # never smokes (`Avwe.Systems.Fire`), so nothing here says so.
  defp standing_miracle(region, miracle, quire_world) do
    heat_w = positive!(miracle, :heat_w, Keyword.fetch!(miracle, :id), "standing miracle")

    %{
      position: position_of(region, Keyword.fetch!(miracle, :at)),
      repr: repr(quire_world, Keyword.fetch!(miracle, :id), miracle),
      hearth: %{
        fuel_kg: 0.0,
        burning: true,
        lit_at: nil,
        out_at: nil,
        power_w: heat_w,
        low_kg: 0.0,
        last_step: Fire.zero_step()
      },
      miracle: %{
        kind: :standing,
        breaks: Keyword.get(miracle, :breaks, []),
        heat_w: heat_w,
        cause: Keyword.get(miracle, :cause, :unknown),
        note: Keyword.get(miracle, :note)
      }
    }
  end

  defp repr(%Quire.World{articles: articles}, id, miracle) do
    case articles[id] do
      %Quire.Article{title: title, summary: summary} ->
        %{name: title, description: summary}

      nil ->
        %{name: Keyword.get(miracle, :name, id), description: Keyword.get(miracle, :description)}
    end
  end

  defp position_of(region, place) do
    Region.get(region, place, :position) ||
      raise ArgumentError, "no place #{inspect(place)} to put a hearth at"
  end

  defp time({year, opts}), do: Calendar.at(year, opts)
  defp time(time) when is_integer(time), do: time
end
