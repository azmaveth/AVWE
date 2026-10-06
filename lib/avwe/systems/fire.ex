defmodule Avwe.Systems.Fire do
  @moduledoc """
  Hearths: fires that eat wood and give off heat and smoke.

  A hearth is an entity with a `:hearth` component (and a `:position` and a
  `:repr`):

      %{fuel_kg: 12.0, burning: false, lit_at: nil, out_at: nil,
        power_w: 5_000.0, low_kg: 1.0, last_step: %{...}}

  Bodies light and put out hearths with the `:kindle` and `:douse` verbs
  (`Avwe.Actions`); a hearth that has been kindled records who lit it last
  (`lit_by`), so a body can tell its own fire's smoke from a stranger's. Every step, each burning hearth burns at its power: dry
  wood gives 16 MJ/kg, so 5 kW is 1.125 kg an hour and 12 kg is a night's
  fire. Consumption is linear and clamped at zero, which is exact at any step
  length: 12 kg at 5 kW goes out at `lit_at + 38_400` whether the world is
  stepped by the minute or by the day.

  `last_step` records what the hearth did in the last step: how long it burned
  (`burn_s`), what it burned (`burned_kg`), the heat it gave (`heat_j`), the
  share that enters the ground under it (`ground_j`, read by the heat system)
  and the share vented to the air (`vented_j`), and the smoke it made
  (`smoke_g`, read by `Avwe.Systems.Smoke`). The split is exact:
  `ground_j + vented_j == heat_j`, `burned_kg == fuel before − fuel after` and
  `smoke_g == 10 · burned_kg`, so budgets downstream close to rounding.

  ## Standing miracles

  A hearth that also carries `miracle: %{kind: :standing, heat_w: w, breaks:
  [...]}` burns without fuel: it never goes out, burns nothing and gives
  `w · dt` joules. Standing miracles never smoke: nothing burns, so `smoke_g`
  is always 0.0 and the smoke system never sees them. When `:dousing` is among
  the things it breaks, `:douse` fails with `:unquenchable`. Nothing here
  names the Last Coal; it is just configured this way.

  ## Events

    * `:fire_lit` (from `:kindle`), `data: %{position, by, ref}`: the body
      that lit it and its intent's ref.
    * `:fire_low` when the fuel falls to `low_kg`, stamped with the exact
      second, `data: %{position}`.
    * `:fire_out` when the fuel is gone (`reason: :fuel`, `by: nil`) or the
      fire is doused (`reason: :doused`, `by: body`, `ref`), stamped with the
      exact second; `out_at` on the hearth records it.

  Felt warmth (`felt/2`) is perception only: no energy moves.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Space}

  @fuel_j_per_kg 16.0e6
  @smoke_g_per_kg 10.0
  @f_ground 0.3
  @at_place_cells 2
  @hot_w_m2 100.0
  @warm_w_m2 20.0
  @faint_w_m2 2.0
  @zero_step %{
    burn_s: 0.0,
    burned_kg: 0.0,
    heat_j: 0.0,
    ground_j: 0.0,
    vented_j: 0.0,
    smoke_g: 0.0,
    miracle?: false
  }

  @type hearth :: %{
          optional(:lit_by) => String.t(),
          fuel_kg: float(),
          burning: boolean(),
          lit_at: Avwe.Calendar.time() | nil,
          out_at: Avwe.Calendar.time() | nil,
          power_w: float(),
          low_kg: float(),
          last_step: map()
        }

  @doc "A hearth's `last_step` when it did nothing."
  @spec zero_step() :: map()
  def zero_step, do: @zero_step

  @doc "How close, in cells, a body must be to a hearth to kindle or douse it."
  @spec at_place_cells() :: pos_integer()
  def at_place_cells, do: @at_place_cells

  @doc "The share of a fire's heat that enters the ground under it."
  @spec ground_share() :: float()
  def ground_share, do: @f_ground

  @impl Avwe.System
  def run(region, tick) do
    region
    |> Region.with_components([:hearth, :position])
    |> Enum.reduce({region, []}, fn id, {acc, events} ->
      hearth = Region.get(acc, id, :hearth)
      position = Region.get(acc, id, :position)
      miracle = standing_miracle(acc, id)

      {hearth, new_events} = burn(hearth, miracle, id, position, tick)
      {Region.put_component(acc, id, :hearth, hearth), events ++ new_events}
    end)
  end

  defp burn(%{burning: false} = hearth, _miracle, _id, _position, _tick) do
    {%{hearth | last_step: @zero_step}, []}
  end

  defp burn(hearth, %{heat_w: heat_w}, _id, _position, tick) do
    heat_j = heat_w * tick.dt
    {ground_j, vented_j} = split(heat_j)

    last_step = %{
      @zero_step
      | burn_s: tick.dt * 1.0,
        heat_j: heat_j,
        ground_j: ground_j,
        vented_j: vented_j,
        miracle?: true
    }

    {%{hearth | last_step: last_step}, []}
  end

  defp burn(hearth, nil, id, position, tick) do
    rate = hearth.power_w / @fuel_j_per_kg
    dt = tick.dt

    # The fuel runs out within this step when the step would burn all of it.
    {burn_s, fuel_after} =
      if hearth.fuel_kg <= rate * dt,
        do: {hearth.fuel_kg / rate, 0.0},
        else: {dt * 1.0, hearth.fuel_kg - rate * dt}

    burned_kg = hearth.fuel_kg - fuel_after
    heat_j = hearth.power_w * burn_s
    {ground_j, vented_j} = split(heat_j)

    last_step = %{
      burn_s: burn_s,
      burned_kg: burned_kg,
      heat_j: heat_j,
      ground_j: ground_j,
      vented_j: vented_j,
      smoke_g: @smoke_g_per_kg * burned_kg,
      miracle?: false
    }

    low = low_events(hearth, fuel_after, rate, id, position, tick.time)
    {out_at, out} = out_events(hearth, fuel_after, burn_s, id, position, tick.time)

    hearth = %{
      hearth
      | fuel_kg: fuel_after,
        burning: out_at == nil,
        out_at: out_at,
        last_step: last_step
    }

    {hearth, low ++ out}
  end

  # The vented share is rounded once; the ground share is then what is left,
  # exactly (Sterbenz: the two parts are within a factor of two of the whole),
  # so ground_j + vented_j == heat_j holds in floating point.
  defp split(heat_j) do
    vented_j = heat_j - @f_ground * heat_j
    {heat_j - vented_j, vented_j}
  end

  defp low_events(%{fuel_kg: before, low_kg: low}, fuel_after, rate, id, position, t0)
       when before > low and low >= fuel_after do
    [
      Event.new(:fire_low,
        entity: id,
        time: t0 + round((before - low) / rate),
        data: %{position: position}
      )
    ]
  end

  defp low_events(_hearth, _after, _rate, _id, _position, _t0), do: []

  defp out_events(_hearth, fuel_after, burn_s, id, position, t0) when fuel_after == 0.0 do
    out_at = t0 + round(burn_s)

    {out_at,
     [
       Event.new(:fire_out,
         entity: id,
         time: out_at,
         data: %{position: position, reason: :fuel, by: nil}
       )
     ]}
  end

  defp out_events(_hearth, _after, _burn_s, _id, _position, _t0), do: {nil, []}

  # Converters

  @doc """
  The hearths within reach of `cell`, as `{id, hearth, distance}` sorted by
  distance then id. Works on a region or a view.
  """
  @spec hearth_near(Region.t() | map(), Space.cell()) :: [{String.t(), hearth(), float()}]
  def hearth_near(%{components: components}, cell) do
    hearths = Map.get(components, :hearth, %{})
    positions = Map.get(components, :position, %{})

    near =
      for {id, hearth} <- hearths,
          position = positions[id],
          distance = Space.distance(cell, position),
          distance <= @at_place_cells,
          do: {id, hearth, distance}

    Enum.sort_by(near, fn {id, _hearth, distance} -> {distance, id} end)
  end

  @doc """
  The warmth a body at `cell` feels from the burning hearths around it:
  `%{ref, name, level, w_m2}` for the strongest, or `nil`. `felt_all/2` lists
  every one.

  A fire radiates half its power into the hemisphere above it, so the
  irradiance at `d` metres is `0.5·P/(2π·d²)` (at least 1 m): `:hot` from
  100 W/m², `:warm` from 20, `:faint` from 2. A 5 kW hearth is `:hot` in its
  own cell and `:faint` one cell away; an 800 W one is `:warm` in its cell and
  nothing beyond.
  """
  @spec felt(map(), Space.cell()) :: %{ref: String.t(), name: String.t(), level: atom()} | nil
  def felt(view, cell), do: view |> felt_all(cell) |> List.first()

  @doc """
  Every burning source within reach of `cell` whose warmth a body there
  feels, as `felt/2` reports them, strongest first (then by id): the fire
  under its nose and the Last Coal beside it are both there.
  """
  @spec felt_all(map(), Space.cell()) :: [map()]
  def felt_all(%{components: components} = view, cell) do
    view
    |> hearth_near(cell)
    |> Enum.filter(fn {_id, hearth, _distance} -> hearth.burning end)
    |> Enum.map(fn {id, hearth, distance} ->
      d_m = max(Space.cell_size_m() * distance, 1.0)
      w_m2 = 0.5 * power_w(hearth, standing_miracle(view, id)) / (2 * :math.pi() * d_m * d_m)
      %{ref: id, name: name(components, id), level: level(w_m2), w_m2: w_m2}
    end)
    |> Enum.reject(&(&1.level == nil))
    |> Enum.sort_by(&{-&1.w_m2, &1.ref})
  end

  @doc "True when the hearth is a standing miracle that cannot be doused."
  @spec unquenchable?(Region.t() | map(), String.t()) :: boolean()
  def unquenchable?(region_or_view, id) do
    case standing_miracle(region_or_view, id) do
      %{breaks: breaks} -> :dousing in breaks
      nil -> false
    end
  end

  @doc "True when the hearth is a standing miracle: it burns without fuel."
  @spec standing?(Region.t() | map(), String.t()) :: boolean()
  def standing?(region_or_view, id), do: standing_miracle(region_or_view, id) != nil

  defp standing_miracle(%{components: components}, id) do
    case get_in(components, [:miracle, id]) do
      %{kind: :standing} = miracle -> miracle
      _other -> nil
    end
  end

  defp power_w(_hearth, %{heat_w: heat_w}), do: heat_w
  defp power_w(%{power_w: power_w}, nil), do: power_w

  defp level(w_m2) when w_m2 >= @hot_w_m2, do: :hot
  defp level(w_m2) when w_m2 >= @warm_w_m2, do: :warm
  defp level(w_m2) when w_m2 >= @faint_w_m2, do: :faint
  defp level(_w_m2), do: nil

  defp name(components, id), do: get_in(components, [:repr, id, :name]) || id
end
