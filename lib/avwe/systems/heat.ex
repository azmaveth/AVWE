defmodule Avwe.Systems.Heat do
  @moduledoc """
  The ground's temperature: a store of heat per cell, warmed by the sun, the
  air, the river's seepage and any fire on it, and cooled to the air and the
  night sky.

  ## Why a per-cell store with no stencil

  Each active cell is one lump of material (`Avwe.Terrain.ground/2`) with a
  heat capacity and an absorptance (§4.2 of the spec), exchanging heat with
  the air (`k_air`), the sky (`k_rad`, a linearised radiation term) and, for
  the bed, the reeds and the silt banks, the reach beside it (`k_riv`, warm
  seepage that falls off with distance from the channel). Lateral conduction
  is left out on purpose: soil moves heat about 0.2 m a day against 10 m
  cells, and what warms the banks is seepage from the reach, which `k_riv`
  models. With no stencil there is no stability limit on the step.

  ## Exact relaxation

  A cell's temperature obeys `C dT/dt = K (T_eq - T)` with constant forcing
  over a step, whose solution is exact for any `dt`: the step uses the
  forcing's exact mean over the interval (`Avwe.Systems.Weather.mean_air_c/2`,
  `Avwe.Systems.Daylight.mean_light/2`) and lands on the exact solution's
  energy. `T1` always lies between `T0` and `T_eq`, so sixty one-minute steps
  and one hour step agree to rounding and a day-long step still makes sense.

  ## The budget

  Energy is stored in joules relative to `t_ref_c` (15 °C), so the totals stay
  small enough for the budget to close to a joule. The six exchange terms of a
  cell sum to its storage change by construction (`E' = E + ΣQ`), and every
  line and both storage totals use Neumaier compensated summation, so
  `delta_storage_mj` equals the lines and `storage_after - storage_before` to
  1e-6 MJ whatever the step. The river and the air are boundary reservoirs:
  the ground books what it takes from them (`river_in/out`, `air_in/out`) and
  nothing flows back. A fire's heat enters its ground cell at `f_ground`
  (30 %); the rest goes up with the smoke.

  ## The active set

  Only cells that can differ from their neighbours are stored: every cell
  within 6.5 cells of the channel, the clay patches, and every hearth's cell.
  Two 1 m² background pseudo-cells, grass and stone, stand for every open cell
  of those materials: open cells of one material see the same forcing and so
  evolve identically. A hearth placed on an open cell later activates it on
  demand, starting from its material's background, which is exactly what the
  dense field would hold there.

  ## Steam

  A reach's banks steam when the reach flows and its silt cells are, on
  average, 8 K above the air at the end of the step. Using the end-of-step air
  is what makes the banks steam in the evening as the air falls. Emits
  `:steam_rising` and `:steam_fading` on the flip, positioned at the reach.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Space, Terrain, Tick}
  alias Avwe.Systems.{Daylight, River, Weather}

  defmodule Field do
    @moduledoc """
    The heat field: static cell data, the energy stored in each cell (J
    relative to `t_ref_c`), which reaches' banks are steaming, and the last
    step's budget in MJ.

    Cells are ordered row-major (`y`, then `x`) with the two background
    pseudo-cells last; `index` maps a cell (or `{:background, material}`) to
    its position in the tuples.
    """

    @zero_step %{
      dt: 0,
      sun_mj: 0.0,
      air_in_mj: 0.0,
      air_out_mj: 0.0,
      sky_in_mj: 0.0,
      sky_out_mj: 0.0,
      river_in_mj: 0.0,
      river_out_mj: 0.0,
      hearths_mj: 0.0,
      miracles_mj: 0.0,
      delta_storage_mj: 0.0,
      storage_before_mj: 0.0,
      storage_after_mj: 0.0
    }

    defstruct t_ref_c: 15.0,
              static: {},
              index: %{},
              energy: {},
              bank_cells: %{},
              steaming: {},
              last_step: @zero_step

    @type cell_key :: Space.cell() | {:background, Terrain.ground()}

    @type static :: %{
            cell: cell_key(),
            material: Terrain.ground(),
            area_m2: float(),
            cap_j_k: float(),
            absorb_m2: float(),
            river: {non_neg_integer(), float()} | nil
          }

    @type t :: %__MODULE__{
            t_ref_c: float(),
            static: tuple(),
            index: %{cell_key() => non_neg_integer()},
            energy: tuple(),
            bank_cells: %{non_neg_integer() => [non_neg_integer()]},
            steaming: tuple(),
            last_step: map()
          }

    @doc "A budget record with every line at zero."
    @spec zero_step() :: map()
    def zero_step, do: @zero_step
  end

  @t_ref_c 15.0
  @cell_m2 100.0
  @background_m2 1.0
  @k_air 15.0
  @k_rad 5.0
  @s_peak 800.0
  @f_ground 0.3
  @steam_dc 8.0
  @warm_dc 8.0
  @hot_dc 15.0
  @cold_dc -2.0
  @near_channel_cells 6.5
  @window 6
  @day 24 * 3_600
  @settle_before_s 2 * @day
  @stopped_limit_s 14 * @day
  @settle_step_s 3_600
  @series_below 1.0e-5
  @wet [:channel_bed, :reeds, :silt]
  @backgrounds [:grass, :stone]
  @lines [
    :sun,
    :air_in,
    :air_out,
    :sky_in,
    :sky_out,
    :river_in,
    :river_out,
    :hearths,
    :miracles,
    :delta,
    :before,
    :after
  ]

  @materials %{
    channel_bed: %{cap_j_m2k: 1.0e6, absorb: 0.30, k_riv_w_m2k: 100.0},
    reeds: %{cap_j_m2k: 1.0e6, absorb: 0.35, k_riv_w_m2k: 40.0},
    silt: %{cap_j_m2k: 2.5e6, absorb: 0.35, k_riv_w_m2k: :by_distance},
    clay: %{cap_j_m2k: 3.0e5, absorb: 0.55, k_riv_w_m2k: 0.0},
    grass: %{cap_j_m2k: 2.0e5, absorb: 0.45, k_riv_w_m2k: 0.0},
    stone: %{cap_j_m2k: 1.5e5, absorb: 0.60, k_riv_w_m2k: 0.0}
  }

  @type forcing :: %{air_c: float(), sky_c: float(), light: float()}
  @type sources :: %{non_neg_integer() => {float(), float()}}

  # Lifecycle

  @impl Avwe.System
  def prepare(%Region{terrain: %Terrain{} = terrain} = region) do
    statics =
      region
      |> active_cells(terrain)
      |> Enum.map(&cell_static(terrain, &1))
      |> Kernel.++(Enum.map(@backgrounds, &background_static/1))

    field =
      %Field{
        t_ref_c: @t_ref_c,
        steaming: Tuple.duplicate(false, length(Terrain.reaches(terrain)))
      }
      |> rebuild(statics, List.duplicate(0.0, length(statics)))
      |> settle(region, terrain)

    put_field(region, field)
  end

  def prepare(region), do: region

  @impl Avwe.System
  def run(
        %Region{terrain: %Terrain{} = terrain, fields: %{heat: %Field{} = field}} = region,
        tick
      ) do
    field = activate_hearths(field, region, terrain)
    t1 = Tick.end_time(tick)
    reaches = reaches(region)

    {field, _last_step} =
      step_field(field, forcing(tick.time, t1), sources_j(region, field), reaches, tick.dt)

    steaming = steaming(field, reaches, Weather.air_c(t1))

    {put_field(region, %{field | steaming: steaming}),
     steam_events(field.steaming, steaming, terrain)}
  end

  def run(region, _tick), do: {region, []}

  # Reducers

  @doc """
  Advances every cell by `dt` seconds under a constant forcing (the step's mean
  air, sky and light) and the given reaches, with `sources` mapping a cell's
  index to the joules `{from_hearths, from_miracles}` entering it this step.
  Returns the field with its new energies and budget, and the budget.
  """
  @spec step_field(Field.t(), forcing(), sources(), tuple(), pos_integer()) :: {Field.t(), map()}
  def step_field(%Field{} = field, forcing, sources, reaches, dt) do
    last = tuple_size(field.static) - 1

    {energies, acc} =
      Enum.map_reduce(0..last//1, new_acc(), fn i, acc ->
        static = elem(field.static, i)
        energy = elem(field.energy, i)
        {hearth_j, miracle_j} = source = Map.get(sources, i, {0.0, 0.0})

        {energy_after, delta, q_air, q_sky, q_riv, q_sun} =
          relax(static, energy, source, forcing, reaches, dt, field.t_ref_c)

        acc = %{
          acc
          | sun: add(acc.sun, q_sun),
            air_in: add(acc.air_in, max(q_air, 0.0)),
            air_out: add(acc.air_out, max(-q_air, 0.0)),
            sky_in: add(acc.sky_in, max(q_sky, 0.0)),
            sky_out: add(acc.sky_out, max(-q_sky, 0.0)),
            river_in: add(acc.river_in, max(q_riv, 0.0)),
            river_out: add(acc.river_out, max(-q_riv, 0.0)),
            hearths: add(acc.hearths, hearth_j),
            miracles: add(acc.miracles, miracle_j),
            delta: add(acc.delta, delta),
            before: add(acc.before, energy),
            after: add(acc.after, energy_after)
        }

        {energy_after, acc}
      end)

    last_step = budget(acc, dt)
    {%{field | energy: List.to_tuple(energies), last_step: last_step}, last_step}
  end

  @doc """
  Adds `cell` to the active set, if it isn't there, holding what the dense
  field would hold: open cells of one material evolve alike, so it starts from
  its material's background energy scaled to its area.
  """
  @spec activate(Field.t(), Terrain.t(), Space.cell()) :: Field.t()
  def activate(%Field{} = field, %Terrain{} = terrain, cell) do
    if Map.has_key?(field.index, cell) do
      field
    else
      static = cell_static(terrain, cell)
      energy = static.area_m2 * background_energy_per_m2(field, static.material)

      {statics, energies} =
        field.static
        |> Tuple.to_list()
        |> Enum.zip(Tuple.to_list(field.energy))
        |> insert({static, energy})
        |> Enum.unzip()

      rebuild(field, statics, energies)
    end
  end

  # Converters

  @doc "The ground temperature at `cell`: its own if active, else its material's background."
  @spec ground_c(Field.t(), Terrain.t(), Space.cell()) :: float()
  def ground_c(%Field{} = field, %Terrain{} = terrain, cell) do
    case Map.fetch(field.index, cell) do
      {:ok, i} -> cell_c(field, i)
      :error -> background_c(field, Terrain.ground(terrain, cell))
    end
  end

  @doc "The temperature of the cell at index `i`."
  @spec cell_c(Field.t(), non_neg_integer()) :: float()
  def cell_c(%Field{} = field, i),
    do: field.t_ref_c + elem(field.energy, i) / elem(field.static, i).cap_j_k

  @doc """
  What a body feels underfoot at `cell`, from a snapshot (or region) carrying
  `fields.heat`, `terrain` and `env.air_c`: `%{air_c, ground_c, ground, steam?}`
  with `ground` one of `:hot`, `:warm`, `:cold` or `nil`. `nil` when the
  snapshot has no heat field.
  """
  @spec at(map(), Space.cell()) :: map() | nil
  def at(
        %{fields: %{heat: %Field{} = field}, terrain: %Terrain{} = terrain, env: env} = view,
        cell
      ) do
    air = env.air_c
    ground = ground_c(field, terrain, cell)
    above = ground - air

    %{
      air_c: air,
      ground_c: ground,
      ground: band(above),
      steam?:
        Terrain.ground(terrain, cell) in @wet and flowing_beside?(view, terrain, cell) and
          above >= @steam_dc
    }
  end

  def at(_view, _cell), do: nil

  @doc "True when reach `k`'s banks are steaming."
  @spec steaming?(Field.t(), non_neg_integer()) :: boolean()
  def steaming?(%Field{steaming: steaming}, k) when k >= 0 and k < tuple_size(steaming),
    do: elem(steaming, k)

  def steaming?(%Field{}, _k), do: false

  @doc """
  The heat sources in a view: burning hearths and standing miracles, as
  `%{id, name, position, power_w, kind}`, sorted by id.
  """
  @spec sources(map()) :: [map()]
  def sources(%{components: components}) do
    hearths = Map.get(components, :hearth, %{})
    positions = Map.get(components, :position, %{})
    miracles = Map.get(components, :miracle, %{})
    repr = Map.get(components, :repr, %{})

    for id <- hearths |> Map.keys() |> Enum.sort(),
        Map.has_key?(positions, id),
        hearths[id].burning do
      source = %{id: id, name: get_in(repr, [id, :name]) || id, position: positions[id]}

      case miracles[id] do
        %{kind: :standing, heat_w: watts} -> Map.merge(source, %{power_w: watts, kind: :miracle})
        _ordinary -> Map.merge(source, %{power_w: hearths[id].power_w, kind: :hearth})
      end
    end
  end

  @doc "The energy stored in the field relative to `t_ref_c`, in MJ (compensated sum)."
  @spec stored_mj(Field.t()) :: float()
  def stored_mj(%Field{energy: energy}) do
    energy
    |> Tuple.to_list()
    |> Enum.reduce({0.0, 0.0}, &add(&2, &1))
    |> total()
    |> Kernel./(1.0e6)
  end

  @doc "The materials: heat capacity per m², absorptance and river coupling per m²."
  @spec materials() :: %{Terrain.ground() => map()}
  def materials, do: @materials

  @doc "A material's time constant against the air and sky, in seconds."
  @spec tau_s(Terrain.ground()) :: float()
  def tau_s(ground), do: @materials[ground].cap_j_m2k / (@k_air + @k_rad)

  @doc """
  Seepage coupling to a flowing reach, in W/m²K, for a material `d` cells from
  the channel: full for the bed and the reeds, falling off through the silt.
  """
  @spec k_riv_w_m2k(Terrain.ground(), float()) :: float()
  def k_riv_w_m2k(:silt, d), do: 40.0 * :math.exp(-(d - 2) / 4)

  def k_riv_w_m2k(ground, _d) when ground in [:channel_bed, :reeds],
    do: @materials[ground].k_riv_w_m2k

  def k_riv_w_m2k(_ground, _d), do: 0.0

  @doc "The share of a fire's heat that enters its ground cell."
  @spec f_ground() :: float()
  def f_ground, do: @f_ground

  # The physics of one cell for one step: the exact solution of
  # C dT/dt = K (T_eq - T) under constant forcing, and the exchange terms
  # evaluated at the time-mean temperature so they sum to the storage change.
  defp relax(static, energy, {hearth_j, miracle_j}, forcing, reaches, dt, t_ref) do
    %{area_m2: a, cap_j_k: cap, absorb_m2: absorb} = static
    %{air_c: air, sky_c: sky, light: light} = forcing
    t0 = t_ref + energy / cap
    {k_riv, t_w} = coupling(static.river, reaches, a)
    k = @k_air + @k_rad + k_riv
    sun_w = @s_peak * absorb * light
    t_eq = equilibrium(a, k, k_riv, t_w, sun_w + (hearth_j + miracle_j) / dt, forcing)
    t_bar = t_eq + (t0 - t_eq) * mean_factor(dt * k * a / cap)

    q_air = a * @k_air * (air - t_bar) * dt
    q_sky = a * @k_rad * (sky - t_bar) * dt
    q_riv = a * k_riv * (t_w - t_bar) * dt
    q_sun = sun_w * dt
    delta = q_air + q_sky + q_riv + q_sun + hearth_j + miracle_j

    {energy + delta, delta, q_air, q_sky, q_riv, q_sun}
  end

  # The temperature a cell settles at under constant forcing and a source of
  # `q_w` watts.
  defp equilibrium(a, k, k_riv, t_w, q_w, %{air_c: air, sky_c: sky}) do
    (a * (@k_air * air + @k_rad * sky + k_riv * t_w) + q_w) / (k * a)
  end

  # (1 - e^-x) / x: the time-mean of e^-t over the step, relative to its start.
  defp mean_factor(x) when x < @series_below, do: 1 - x / 2 + x * x / 6
  defp mean_factor(x), do: (1 - :math.exp(-x)) / x

  defp coupling(nil, _reaches, _a), do: {0.0, 0.0}

  defp coupling({k, watts_per_k}, reaches, a) when k < tuple_size(reaches) do
    case elem(reaches, k) do
      %{silent: false, temp_c: t_w} -> {watts_per_k / a, t_w}
      _silent -> {0.0, 0.0}
    end
  end

  defp coupling(_river, _reaches, _a), do: {0.0, 0.0}

  # Neumaier compensated summation: {sum, compensation}.
  defp add({sum, c}, x) do
    t = sum + x

    if abs(sum) >= abs(x),
      do: {t, c + (sum - t + x)},
      else: {t, c + (x - t + sum)}
  end

  defp total({sum, c}), do: sum + c

  defp new_acc, do: Map.new(@lines, &{&1, {0.0, 0.0}})

  defp budget(acc, dt) do
    mj = fn line -> total(acc[line]) / 1.0e6 end

    %{
      dt: dt,
      sun_mj: mj.(:sun),
      air_in_mj: mj.(:air_in),
      air_out_mj: mj.(:air_out),
      sky_in_mj: mj.(:sky_in),
      sky_out_mj: mj.(:sky_out),
      river_in_mj: mj.(:river_in),
      river_out_mj: mj.(:river_out),
      hearths_mj: mj.(:hearths),
      miracles_mj: mj.(:miracles),
      delta_storage_mj: mj.(:delta),
      storage_before_mj: mj.(:before),
      storage_after_mj: mj.(:after)
    }
  end

  # Settling at prepare

  # The field at the region's starting time: every cell at its daily-mean
  # equilibrium with the river flowing, then two days of hourly steps to set
  # the diurnal phase and, if the spring has stopped, as long as it has been
  # stopped (up to two weeks) under the river as it is now.
  defp settle(field, region, terrain) do
    spring = spring(region)
    daily = Weather.daily_mean_air_c()

    mean_forcing = %{
      air_c: daily,
      sky_c: daily - Weather.sky_drop(),
      light: Daylight.mean_light(0, @day)
    }

    river_era =
      if spring,
        do: River.steady_reaches(terrain, spring.natural_m3_s, spring.temp_c, daily),
        else: {}

    standing_w = standing_w(region, field)
    stop = region.time - stopped_s(region, spring)

    field
    |> equilibrate(mean_forcing, standing_w, river_era)
    |> replay(stop - @settle_before_s, stop, standing_w, river_era)
    |> replay(stop, region.time, standing_w, reaches(region))
    |> then(&%{&1 | steaming: steaming(&1, reaches(region), Weather.air_c(region.time))})
    |> Map.put(:last_step, Field.zero_step())
  end

  defp spring(region) do
    case Region.get(region, River.id(), :river) do
      %{source: source} -> Region.get(region, source, :spring)
      nil -> nil
    end
  end

  defp stopped_s(region, %{flow_m3_s: flow, changed_at: changed_at}) when flow == 0,
    do: (region.time - changed_at) |> min(@stopped_limit_s) |> max(0)

  defp stopped_s(_region, _spring), do: 0

  # Watts entering the ground from standing miracles, by cell index.
  defp standing_w(region, field) do
    region
    |> Region.with_components([:hearth, :position, :miracle])
    |> Enum.reduce(%{}, fn id, acc ->
      case Region.get(region, id, :miracle) do
        %{kind: :standing, heat_w: watts} ->
          i = Map.fetch!(field.index, Region.get(region, id, :position))
          Map.update(acc, i, @f_ground * watts, &(&1 + @f_ground * watts))

        _event ->
          acc
      end
    end)
  end

  defp equilibrate(field, forcing, standing_w, reaches) do
    energies =
      for {static, i} <- Enum.with_index(Tuple.to_list(field.static)) do
        %{area_m2: a, cap_j_k: cap, absorb_m2: absorb} = static
        {k_riv, t_w} = coupling(static.river, reaches, a)
        q_w = @s_peak * absorb * forcing.light + Map.get(standing_w, i, 0.0)
        cap * (equilibrium(a, @k_air + @k_rad + k_riv, k_riv, t_w, q_w, forcing) - field.t_ref_c)
      end

    %{field | energy: List.to_tuple(energies)}
  end

  # Replays the field from `from` to `to` in hourly steps and a remainder.
  # Cells that share a material, an area, a river coupling and a source see
  # identical inputs and hold identical energy throughout, so each such class
  # is stepped once and its members copy the result: bit for bit what stepping
  # every cell would give, at a fraction of the cost.
  defp replay(field, from, to, _standing_w, _reaches) when from >= to, do: field

  defp replay(field, from, to, standing_w, reaches) do
    classes =
      field.static
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.group_by(fn {static, i} -> {static, Map.get(standing_w, i, 0.0)} end)
      |> Enum.map(fn {{static, watts}, [{_static, first} | _] = members} ->
        {static, watts, elem(field.energy, first), Enum.map(members, &elem(&1, 1))}
      end)

    stepped =
      Enum.reduce(hourly_steps(from, to), classes, fn {t0, dt}, classes ->
        forcing = forcing(t0, t0 + dt)

        Enum.map(classes, fn {static, watts, energy, members} ->
          {energy, _delta, _air, _sky, _riv, _sun} =
            relax(static, energy, {0.0, watts * dt}, forcing, reaches, dt, field.t_ref_c)

          {static, watts, energy, members}
        end)
      end)

    by_index =
      Enum.reduce(stepped, %{}, fn {_static, _watts, energy, members}, acc ->
        Enum.reduce(members, acc, &Map.put(&2, &1, energy))
      end)

    energies = Enum.map(0..(tuple_size(field.static) - 1)//1, &Map.fetch!(by_index, &1))
    %{field | energy: List.to_tuple(energies)}
  end

  defp hourly_steps(from, to) do
    Stream.unfold(from, fn
      t when t >= to -> nil
      t -> {{t, min(@settle_step_s, to - t)}, t + min(@settle_step_s, to - t)}
    end)
    |> Enum.to_list()
  end

  defp forcing(t0, t1) do
    %{
      air_c: Weather.mean_air_c(t0, t1),
      sky_c: Weather.mean_sky_c(t0, t1),
      light: Daylight.mean_light(t0, t1)
    }
  end

  # The active set and the static cell data

  defp active_cells(region, terrain) do
    near_channel =
      for {cx, cy} = point <- Terrain.channel(terrain),
          dx <- -@window..@window,
          dy <- -@window..@window,
          cell = {cx + dx, cy + dy},
          inside?(terrain, cell),
          Space.distance(cell, point) <= @near_channel_cells,
          do: cell

    clay =
      for %{center: {cx, cy} = center, radius_cells: radius} <- terrain.clay,
          reach = trunc(Float.ceil(radius * 1.0)),
          dx <- -reach..reach,
          dy <- -reach..reach,
          cell = {cx + dx, cy + dy},
          inside?(terrain, cell),
          Space.distance(cell, center) <= radius,
          do: cell

    hearths =
      for id <- Region.with_components(region, [:hearth, :position]),
          do: Region.get(region, id, :position)

    (near_channel ++ clay ++ hearths)
    |> Enum.uniq()
    |> Enum.sort_by(fn {x, y} -> {y, x} end)
  end

  defp inside?(%Terrain{width: width, height: height}, {x, y}),
    do: x >= 0 and x < width and y >= 0 and y < height

  defp cell_static(terrain, cell) do
    material = Terrain.ground(terrain, cell)
    static(cell, material, @cell_m2, river_coupling(terrain, material, cell))
  end

  defp background_static(material),
    do: static({:background, material}, material, @background_m2, nil)

  defp static(key, material, area, river) do
    %{cap_j_m2k: cap, absorb: absorb} = @materials[material]

    %{
      cell: key,
      material: material,
      area_m2: area,
      cap_j_k: cap * area,
      absorb_m2: absorb * area,
      river: river
    }
  end

  # `{reach, W/K}` for a wet cell beside a channel, else nil.
  defp river_coupling(terrain, material, cell) when material in @wet do
    case Terrain.nearest_channel(terrain, cell) do
      nil ->
        nil

      {index, _point, d} ->
        {Terrain.reach_of(terrain, index), k_riv_w_m2k(material, d) * @cell_m2}
    end
  end

  defp river_coupling(_terrain, _material, _cell), do: nil

  defp rebuild(field, statics, energies) do
    indexed = Enum.with_index(statics)

    bank_cells =
      indexed
      |> Enum.filter(fn {static, _i} -> static.material == :silt and static.river != nil end)
      |> Enum.group_by(fn {static, _i} -> elem(static.river, 0) end, fn {_static, i} -> i end)

    %{
      field
      | static: List.to_tuple(statics),
        index: Map.new(indexed, fn {static, i} -> {static.cell, i} end),
        energy: List.to_tuple(energies),
        bank_cells: bank_cells
    }
  end

  # Inserts a cell in row-major position, ahead of the backgrounds.
  defp insert(pairs, {static, _energy} = pair) do
    {before, rest} =
      Enum.split_while(pairs, fn {other, _} -> before?(other.cell, static.cell) end)

    before ++ [pair | rest]
  end

  defp before?({:background, _material}, _cell), do: false
  defp before?({x, y}, {cx, cy}), do: {y, x} < {cy, cx}

  defp background_energy_per_m2(field, material) do
    i = Map.fetch!(field.index, {:background, background_of(material)})
    elem(field.energy, i) / elem(field.static, i).area_m2
  end

  defp background_c(field, material),
    do: cell_c(field, Map.fetch!(field.index, {:background, background_of(material)}))

  # Wet and clay cells are always active, so only grass and stone are ever
  # asked for; anything else reads as grass rather than failing.
  defp background_of(material) when material in @backgrounds, do: material
  defp background_of(_material), do: :grass

  # Sources and activation in run

  defp activate_hearths(field, region, terrain) do
    region
    |> Region.with_components([:hearth, :position])
    |> Enum.reduce(field, &activate(&2, terrain, Region.get(region, &1, :position)))
  end

  # Joules entering each cell this step from hearths and from standing
  # miracles, read from the fire system's `last_step` on each hearth.
  defp sources_j(region, field) do
    region
    |> Region.with_components([:hearth, :position])
    |> Enum.reduce(%{}, fn id, acc ->
      i = Map.fetch!(field.index, Region.get(region, id, :position))
      %{ground_j: joules, miracle?: miracle?} = Region.get(region, id, :hearth).last_step
      added = if miracle?, do: {0.0, joules}, else: {joules, 0.0}
      Map.update(acc, i, added, fn {h, m} -> {h + elem(added, 0), m + elem(added, 1)} end)
    end)
  end

  # Steam

  defp steaming(field, reaches, air_c) do
    for k <- 0..(tuple_size(field.steaming) - 1)//1 do
      case Map.get(field.bank_cells, k, []) do
        [] -> false
        cells -> flowing?(reaches, k) and bank_above_air(field, cells, air_c) >= @steam_dc
      end
    end
    |> List.to_tuple()
  end

  defp bank_above_air(field, cells, air_c) do
    cells
    |> Enum.reduce({0.0, 0.0}, fn i, acc -> add(acc, cell_c(field, i) - air_c) end)
    |> total()
    |> Kernel./(length(cells))
  end

  defp flowing?(reaches, k) when k < tuple_size(reaches), do: not elem(reaches, k).silent
  defp flowing?(_reaches, _k), do: false

  defp steam_events(before, after_step, terrain) do
    reaches = Terrain.reaches(terrain)

    for k <- 0..(tuple_size(after_step) - 1)//1,
        elem(before, k) != elem(after_step, k) do
      type = if elem(after_step, k), do: :steam_rising, else: :steam_fading
      Event.new(type, entity: River.id(), data: %{reach: k, position: Enum.at(reaches, k).mid})
    end
  end

  defp flowing_beside?(view, terrain, cell) do
    case Terrain.nearest_channel(terrain, cell) do
      nil -> false
      {index, _point, _d} -> flowing?(reaches(view), Terrain.reach_of(terrain, index))
    end
  end

  # Shared lookups

  defp reaches(%{components: components}) do
    case get_in(components, [:river, River.id()]) do
      %{reaches: reaches} -> reaches
      nil -> {}
    end
  end

  defp put_field(%Region{fields: fields} = region, field),
    do: %{region | fields: Map.put(fields, :heat, field)}

  defp band(above) when above >= @hot_dc, do: :hot
  defp band(above) when above >= @warm_dc, do: :warm
  defp band(above) when above <= @cold_dc, do: :cold
  defp band(_above), do: nil
end
