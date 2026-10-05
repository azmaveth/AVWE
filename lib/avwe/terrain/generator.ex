defmodule Avwe.Terrain.Generator do
  @moduledoc """
  Generates terrain from a world's terrain spec and the positions of its
  places. Pure and seeded: the same seed and pins always give the same land.

  ## Spec

      river: [
        through: ["the-dry-bend", {"ember-reach", beside: :east, cells: 6}, "willow-docks"],
        exit: :south,
        source: [from: "the-dry-bend", bearing: 20..70, cells: 45..70]
      ],
      rises: [{"ashwarden-lodge", height_m: 14, radius_cells: 18}],
      clay: [{"ember-reach", radius_cells: 4}]

  The river starts at a source placed by the generator: `cells` away from the
  `from` place, on a compass bearing in degrees (0 is north, 90 east). It then
  passes through each `through` place in order (or `beside` it, `cells` away)
  and leaves the map at the `exit` edge. Between those points it meanders, by
  a seeded midpoint displacement, but it always passes exactly through them.
  """

  alias Avwe.{Rng, Space, Terrain}

  @meander 0.15
  @meander_depth 2
  @margin 8

  @doc """
  Generates terrain. `places` maps place ids to cells. Options: `:seed`,
  `:width`, `:height`.
  """
  @spec generate(keyword(), %{String.t() => Space.cell()}, keyword()) :: Terrain.t()
  def generate(spec, places, opts) do
    seed = Keyword.fetch!(opts, :seed)
    size = {Keyword.fetch!(opts, :width), Keyword.fetch!(opts, :height)}
    rng = Rng.state(seed, :terrain, 0, __MODULE__)

    channel =
      case Keyword.fetch(spec, :river) do
        {:ok, river} -> river_channel(river, places, size, rng)
        :error -> []
      end

    Terrain.new(
      width: elem(size, 0),
      height: elem(size, 1),
      seed: seed,
      channel: channel,
      rises:
        for(
          {place, rise} <- Keyword.get(spec, :rises, []),
          do: Map.new([{:center, places[place]} | rise])
        ),
      clay:
        for(
          {place, clay} <- Keyword.get(spec, :clay, []),
          do: Map.new([{:center, places[place]} | clay])
        )
    )
  end

  defp river_channel(river, places, size, rng) do
    {source, rng} = source(Keyword.fetch!(river, :source), places, size, rng)
    through = Enum.map(Keyword.fetch!(river, :through), &waypoint(&1, places))
    {exit, rng} = exit(Keyword.fetch!(river, :exit), List.last(through), size, rng)

    {points, _rng} =
      [source | through]
      |> Kernel.++([exit])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map_reduce(rng, fn [a, b], acc ->
        {mids, acc} = meander(a, b, @meander_depth, acc)
        {[a | mids], acc}
      end)

    (points ++ [exit])
    |> rasterize()
    |> Enum.map(&Space.clamp(&1, elem(size, 0)))
    |> Enum.dedup()
  end

  defp source(spec, places, {width, height}, rng) do
    {x, y} = Map.fetch!(places, Keyword.fetch!(spec, :from))
    {bearing, rng} = pick(Keyword.fetch!(spec, :bearing), rng)
    {cells, rng} = pick(Keyword.fetch!(spec, :cells), rng)
    radians = bearing * :math.pi() / 180

    cell = {
      (x + :math.sin(radians) * cells) |> round() |> max(@margin) |> min(width - 1 - @margin),
      (y - :math.cos(radians) * cells) |> round() |> max(@margin) |> min(height - 1 - @margin)
    }

    {cell, rng}
  end

  defp waypoint(place, places) when is_binary(place), do: Map.fetch!(places, place)

  defp waypoint({place, opts}, places) do
    {x, y} = Map.fetch!(places, place)
    {dx, dy} = unit(Keyword.fetch!(opts, :beside))
    cells = Keyword.fetch!(opts, :cells)
    {x + dx * cells, y + dy * cells}
  end

  defp exit(edge, {x, y}, {width, height}, rng) do
    {shift, rng} = pick(-12..12, rng)
    shift = round(shift)

    cell =
      case edge do
        :south -> {clamp(x + shift, width), height - 1}
        :north -> {clamp(x + shift, width), 0}
        :east -> {width - 1, clamp(y + shift, height)}
        :west -> {0, clamp(y + shift, height)}
      end

    {cell, rng}
  end

  # Midpoints between a and b, each pushed sideways by a seeded amount.
  defp meander(_a, _b, 0, rng), do: {[], rng}

  defp meander({ax, ay} = a, {bx, by} = b, depth, rng) do
    {r, rng} = :rand.uniform_s(rng)
    length = Space.distance(a, b)
    {px, py} = if length == 0, do: {0, 0}, else: {-(by - ay) / length, (bx - ax) / length}
    push = (r * 2 - 1) * @meander * length
    mid = {round((ax + bx) / 2 + px * push), round((ay + by) / 2 + py * push)}

    {before, rng} = meander(a, mid, depth - 1, rng)
    {after_mid, rng} = meander(mid, b, depth - 1, rng)
    {before ++ [mid | after_mid], rng}
  end

  defp rasterize(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [{ax, ay}, {bx, by}] ->
      steps = max(abs(bx - ax), abs(by - ay))

      for i <- 0..max(steps - 1, 0),
          do:
            {round(ax + (bx - ax) * i / max(steps, 1)), round(ay + (by - ay) * i / max(steps, 1))}
    end)
    |> Kernel.++([List.last(points)])
    |> Enum.dedup()
  end

  defp pick(first..last//_step, rng) do
    {r, rng} = :rand.uniform_s(rng)
    {first + r * (last - first), rng}
  end

  defp unit(:east), do: {1, 0}
  defp unit(:west), do: {-1, 0}
  defp unit(:north), do: {0, -1}
  defp unit(:south), do: {0, 1}

  defp clamp(value, size), do: value |> max(0) |> min(size - 1)
end
