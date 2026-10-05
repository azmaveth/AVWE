defmodule Avwe.Systems.Smoke do
  @moduledoc """
  Woodsmoke: where it drifts, how it thins, and who smells it.

  Smoke lives in `region.fields.smoke` as a list of puffs, each a parcel of
  grams at a fractional cell position with a mass-weighted emission time:

      %{puffs: [%{x: 94.5, y: 111.2, g: 0.18, born: 1.0e9}], last_step: %{...}}

  ## The model

  Each step, every puff decays with a 15 minute time constant (dispersion out
  of the layer a nose lives in) and drifts with the region's wind (`env.wind`,
  constant). A puff older than five time constants, lighter than `@g_min` or
  off the map is dropped and booked as such. Then every hearth that smoked
  this step (`hearth.last_step.smoke_g`, from `Avwe.Systems.Fire`) adds one
  puff holding what survives of its smoke, released uniformly over the time it
  burned and decaying until the end of the step. That survived mass and its
  decay-weighted mean age have closed forms, so the mass is exact at any step
  length: a minute's step leaves a fresh puff just downwind, an hour's step
  leaves one puff at the plume's centre of mass. Only the plume's shape
  coarsens with long steps. A fresh puff is judged like an old one: too light
  it is dropped, and blown off the map within the step it is booked as left
  at once rather than kept for a step.

  ## Conservation

  `last_step` records, in grams, what was emitted, what survived of it, what
  decayed, what was dropped and what left the map, with the storage before and
  after. Storage changes only by `emitted − decayed − dropped − left`; sums are
  Neumaier-compensated so the identity closes to rounding.

  ## Smell

  A body's nose sees the smoke as a surface density: each puff is a Gaussian
  whose width grows at 0.3 m/s from 5 m. The level (`:faint`, `:clear`,
  `:thick` or `:none`) lives in the body's `:nose` component, and a change
  emits `:smoke_smelled` (`data: %{level, from}`, the wind's direction) or
  `:smoke_faded`. Nothing here draws random numbers.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Space, Tick}

  @tau_s 900.0
  @max_age_s 4_500.0
  # Below this a puff is dropped. 1 mg keeps a minute's puff from a 5 kW
  # hearth (0.18 g) alive until it reaches the age limit, so long and short
  # steps leave the same plume.
  @g_min 1.0e-3
  @sigma0_m 5.0
  @spread_m_s 0.3
  @default_width 256
  @default_wind %{from: "south-west", m_s: 2.0}
  @series_below 1.0e-3
  @thick 1.0e-3
  @clear 1.0e-4
  @faint 1.0e-5
  @zero_step %{
    emitted_g: 0.0,
    survived_g: 0.0,
    decayed_g: 0.0,
    dropped_g: 0.0,
    left_g: 0.0,
    storage_before_g: 0.0,
    storage_after_g: 0.0
  }

  @type level :: :none | :faint | :clear | :thick
  @type puff :: %{x: float(), y: float(), g: float(), born: float()}
  @type field :: %{puffs: [puff()], last_step: map()}

  @doc "The smoke field with no smoke in it."
  @spec new() :: field()
  def new, do: %{puffs: [], last_step: @zero_step}

  @doc "The wind assumed when the region has none: a light south-westerly."
  @spec default_wind() :: map()
  def default_wind, do: @default_wind

  @impl Avwe.System
  def prepare(region), do: %{region | fields: Map.put_new(region.fields, :smoke, new())}

  @impl Avwe.System
  def run(region, tick) do
    field = Map.get(region.fields, :smoke, new())
    wind = Map.get(region.env, :wind, @default_wind)
    width = map_width(region)
    t1 = Tick.end_time(tick)

    acc = %{
      emitted: zero(),
      survived: zero(),
      decayed: zero(),
      dropped: zero(),
      left: zero(),
      before: zero()
    }

    {kept, acc} = age_puffs(field.puffs, acc, wind, width, tick)
    {fresh, acc} = emit_puffs(region, acc, wind, width, tick)
    puffs = Enum.sort_by(kept ++ fresh, &{&1.born, &1.x, &1.y})

    last_step = %{
      emitted_g: total(acc.emitted),
      survived_g: total(acc.survived),
      decayed_g: total(acc.decayed),
      dropped_g: total(acc.dropped),
      left_g: total(acc.left),
      storage_before_g: total(acc.before),
      storage_after_g: puffs |> Enum.map(& &1.g) |> sum()
    }

    field = %{field | puffs: puffs, last_step: last_step}
    region = %{region | fields: Map.put(region.fields, :smoke, field)}
    smell(region, field, wind, t1)
  end

  # Decay, drift and cull the puffs already in the air, in list order.
  defp age_puffs(puffs, acc, wind, width, tick) do
    t1 = Tick.end_time(tick)
    fade = :math.exp(-tick.dt / @tau_s)
    {dx, dy} = drift_cells(wind, tick.dt)

    {kept, acc} =
      Enum.reduce(puffs, {[], acc}, fn puff, {kept, acc} ->
        g = puff.g * fade
        moved = %{puff | g: g, x: puff.x + dx, y: puff.y + dy}

        acc =
          acc
          |> add(:before, puff.g)
          |> add(:decayed, puff.g - g)

        cond do
          t1 - puff.born > @max_age_s or g < @g_min -> {kept, add(acc, :dropped, g)}
          not on_map?(moved, width) -> {kept, add(acc, :left, g)}
          true -> {[moved | kept], acc}
        end
      end)

    {Enum.reverse(kept), acc}
  end

  # One puff per hearth that smoked this step: the closed-form survived mass
  # of smoke released uniformly over [t0, t0 + burn_s] and decaying until t1,
  # placed at its decay-weighted mean age along the wind. Culled on the same
  # terms as an aged puff: too light is dropped, off the map has left.
  defp emit_puffs(region, acc, wind, width, tick) do
    t1 = Tick.end_time(tick)

    region
    |> Region.with_components([:hearth, :position])
    |> Enum.map(&{Region.get(region, &1, :position), Region.get(region, &1, :hearth).last_step})
    |> Enum.filter(fn {_position, last_step} -> last_step.smoke_g > 0 end)
    |> Enum.reduce({[], acc}, fn {{hx, hy}, %{smoke_g: m, burn_s: b}}, {fresh, acc} ->
      survived = survived(m, b, tick.dt)
      age = mean_age(b, tick.dt)
      {dx, dy} = drift_cells(wind, age)
      puff = %{g: survived, born: t1 - age, x: hx + 0.5 + dx, y: hy + 0.5 + dy}

      acc =
        acc
        |> add(:emitted, m)
        |> add(:survived, survived)
        |> add(:decayed, m - survived)

      cond do
        survived < @g_min -> {fresh, add(acc, :dropped, survived)}
        not on_map?(puff, width) -> {fresh, add(acc, :left, survived)}
        true -> {[puff | fresh], acc}
      end
    end)
    |> then(fn {fresh, acc} -> {Enum.reverse(fresh), acc} end)
  end

  # m · exp(−dt/τ) · (τ/b)(exp(b/τ) − 1), written so nothing overflows.
  defp survived(m, b, dt) when b / @tau_s < @series_below do
    r = b / @tau_s
    m * :math.exp(-dt / @tau_s) * (1 + r / 2 + r * r / 6)
  end

  defp survived(m, b, dt) do
    m * (@tau_s / b) * (:math.exp((b - dt) / @tau_s) - :math.exp(-dt / @tau_s))
  end

  # dt − b + τ − b/(exp(b/τ) − 1): the decay-weighted mean age at t1 of smoke
  # released uniformly over [t0, t0 + b].
  defp mean_age(b, dt) when b / @tau_s < @series_below, do: dt - b / 2

  defp mean_age(b, dt) do
    r = b / @tau_s
    tail = if r > 50, do: b * :math.exp(-r), else: b / (:math.exp(r) - 1)
    dt - b + @tau_s - tail
  end

  defp on_map?(%{x: x, y: y}, width), do: x >= 0 and x < width and y >= 0 and y < width

  defp map_width(%Region{terrain: %{width: width}}), do: width
  defp map_width(_region), do: @default_width

  # Smell

  defp smell(region, field, wind, t1) do
    region
    |> Region.with_components([:body, :position])
    |> Enum.reduce({region, []}, fn body, {acc, events} ->
      level = field |> density_g_m2(Region.get(acc, body, :position), t1) |> level()

      if level == nose_level(Region.get(acc, body, :nose)) do
        {acc, events}
      else
        {Region.put_component(acc, body, :nose, %{smoke: level}),
         events ++ [smell_event(body, level, wind)]}
      end
    end)
  end

  defp nose_level(%{smoke: level}), do: level
  defp nose_level(_no_nose), do: :none

  defp smell_event(body, :none, _wind), do: Event.new(:smoke_faded, entity: body, data: %{})

  defp smell_event(body, level, wind) do
    Event.new(:smoke_smelled, entity: body, data: %{level: level, from: wind.from})
  end

  # Converters

  @doc """
  How far the wind carries a parcel in `seconds`, in cells: a wind *from* the
  north moves smoke south (+y).
  """
  @spec drift_cells(map(), number()) :: {float(), float()}
  def drift_cells(%{from: from, m_s: m_s}, seconds) do
    index =
      Enum.find_index(Space.directions(), &(&1 == from)) ||
        raise ArgumentError, "unknown wind direction #{inspect(from)}"

    radians = index * :math.pi() / 4
    cells = m_s * seconds / Space.cell_size_m()
    {-:math.sin(radians) * cells, :math.cos(radians) * cells}
  end

  @doc """
  The smoke at the centre of `cell` at `time`, in g/m²: the sum of the puffs'
  Gaussians, each 5 m wide at birth and spreading at 0.3 m/s.
  """
  @spec density_g_m2(field(), Space.cell(), number()) :: float()
  def density_g_m2(%{puffs: puffs}, {x, y}, time) do
    cx = x + 0.5
    cy = y + 0.5

    puffs
    |> Enum.map(fn puff ->
      sigma = @sigma0_m + @spread_m_s * (time - puff.born)
      d2_m2 = Space.cell_size_m() ** 2 * ((puff.x - cx) ** 2 + (puff.y - cy) ** 2)
      puff.g / (2 * :math.pi() * sigma * sigma) * :math.exp(-d2_m2 / (2 * sigma * sigma))
    end)
    |> sum()
  end

  @doc "What a nose makes of a smoke density in g/m²."
  @spec level(float()) :: level()
  def level(density) when density >= @thick, do: :thick
  def level(density) when density >= @clear, do: :clear
  def level(density) when density >= @faint, do: :faint
  def level(_density), do: :none

  # Neumaier compensated sums: {sum, compensation}.

  defp zero, do: {0.0, 0.0}

  defp add(acc, key, x), do: Map.update!(acc, key, &neumaier(&1, x))

  defp neumaier({sum, c}, x) do
    t = sum + x
    c = if abs(sum) >= abs(x), do: c + (sum - t + x), else: c + (x - t + sum)
    {t, c}
  end

  defp total({sum, c}), do: sum + c

  defp sum(values), do: values |> Enum.reduce(zero(), &neumaier(&2, &1)) |> total()
end
