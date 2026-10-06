defmodule Avwe.Terrain do
  @moduledoc """
  The shape of the land. Pure and static.

  Terrain is generated once from the world seed and Quire's map pins (see
  `Avwe.Terrain.Generator`). It is kept as a small description rather than a
  grid: the river's channel as a line of cells from source to exit, plus the
  rises and clay ground that places add. Elevation and ground are computed for
  any cell on demand, so the same terrain always answers the same way.

  ## Ground

  From the channel outward: the channel bed (2 cells wide), reeds along its
  edges, silt banks out to 60 m, and beyond them grass, or stone on high
  ground. Places listed as clay (the town's streets) override silt and grass.

  ## Elevation

  The channel bed falls evenly from 40 m at the source to 0 m where it leaves
  the map, so water always runs downstream. The land rises 0.25 m per cell
  away from the channel, plus each rise, plus a little seeded noise away from
  the channel.

  ## Reaches

  The channel is divided into reaches of 10 cells (100 m), the units the river
  system simulates.
  """

  alias Avwe.Space

  @bucket 8
  @bed_half_width 1.0
  @reed_width 2.0
  @bank_width 6.0
  @source_elevation_m 40.0
  @bed_depth_m 1.5
  @bank_grade_m_per_cell 0.25
  @stone_elevation_m 50.0
  @noise_m 1.5
  @noise_scale 16
  @reach_cells 10
  @near_channel_cells 8

  @enforce_keys [:width, :height, :seed]
  defstruct [
    :width,
    :height,
    :seed,
    channel: {},
    lengths: {},
    buckets: %{},
    reaches: {},
    rises: [],
    clay: []
  ]

  @type ground :: :channel_bed | :reeds | :clay | :silt | :stone | :grass

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          seed: integer(),
          channel: tuple(),
          lengths: tuple(),
          buckets: map(),
          reaches: tuple(),
          rises: [%{center: Space.cell(), height_m: number(), radius_cells: number()}],
          clay: [%{center: Space.cell(), radius_cells: number()}]
        }

  # Constructor

  @doc """
  Builds terrain from a channel (cells from source to exit; may be empty), rises
  and clay patches.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    channel = Keyword.get(opts, :channel, [])

    %__MODULE__{
      width: Keyword.fetch!(opts, :width),
      height: Keyword.fetch!(opts, :height),
      seed: Keyword.fetch!(opts, :seed),
      channel: List.to_tuple(channel),
      lengths: channel |> cumulative_lengths() |> List.to_tuple(),
      buckets:
        Enum.group_by(Enum.with_index(channel), fn {{x, y}, _i} ->
          {div(x, @bucket), div(y, @bucket)}
        end),
      reaches: channel |> split_reaches() |> List.to_tuple(),
      rises: Keyword.get(opts, :rises, []),
      clay: Keyword.get(opts, :clay, [])
    }
  end

  # Converters

  @doc "How close, in cells, a body must be to the channel to see and follow it."
  @spec near_channel_cells() :: pos_integer()
  def near_channel_cells, do: @near_channel_cells

  @doc "True when the terrain has a river channel."
  @spec river?(t()) :: boolean()
  def river?(%__MODULE__{channel: channel}), do: tuple_size(channel) > 1

  @doc "The cell where the channel begins: the river's source."
  @spec source(t()) :: Space.cell()
  def source(%__MODULE__{channel: channel}), do: elem(channel, 0)

  @doc "The channel's cells, from source to exit."
  @spec channel(t()) :: [Space.cell()]
  def channel(%__MODULE__{channel: channel}), do: Tuple.to_list(channel)

  @doc """
  The channel cell nearest to `cell`, as `{index, cell, distance_in_cells}`,
  or `nil` when there is no channel.
  """
  @spec nearest_channel(t(), Space.cell()) :: {non_neg_integer(), Space.cell(), float()} | nil
  def nearest_channel(%__MODULE__{} = terrain, {x, y} = cell) do
    if river?(terrain) do
      {bx, by} = {div(x, @bucket), div(y, @bucket)}

      nearby =
        for dx <- -3..3,
            dy <- -3..3,
            point <- Map.get(terrain.buckets, {bx + dx, by + dy}, []),
            do: point

      case closest(nearby, cell) do
        {_index, _point, distance} = found when distance <= 3 * @bucket -> found
        _far -> terrain.channel |> Tuple.to_list() |> Enum.with_index() |> closest(cell)
      end
    end
  end

  @doc "Height above the channel's exit, in metres."
  @spec elevation(t(), Space.cell()) :: float()
  def elevation(%__MODULE__{} = terrain, cell) do
    base =
      case nearest_channel(terrain, cell) do
        nil -> 0.0
        {index, _point, distance} -> channel_elevation(terrain, index) + bank(distance)
      end

    base + rises(terrain, cell) + noise(terrain, cell)
  end

  @doc "What the ground is made of at `cell`."
  @spec ground(t(), Space.cell()) :: ground()
  def ground(%__MODULE__{} = terrain, cell) do
    distance =
      case nearest_channel(terrain, cell) do
        nil -> :infinity
        {_index, _point, distance} -> distance
      end

    cond do
      distance <= @bed_half_width -> :channel_bed
      distance <= @reed_width -> :reeds
      Enum.any?(terrain.clay, &(Space.distance(cell, &1.center) <= &1.radius_cells)) -> :clay
      distance <= @bank_width -> :silt
      elevation(terrain, cell) >= @stone_elevation_m -> :stone
      true -> :grass
    end
  end

  @doc "The reach a channel cell belongs to."
  @spec reach_of(t(), non_neg_integer()) :: non_neg_integer()
  def reach_of(%__MODULE__{reaches: reaches}, index),
    do: min(div(index, @reach_cells), tuple_size(reaches) - 1)

  @doc "The river's reaches, from source to exit: `%{first, last, mid, length_m}`."
  @spec reaches(t()) :: [map()]
  def reaches(%__MODULE__{reaches: reaches}), do: Tuple.to_list(reaches)

  @doc """
  Waypoints along the channel from `index` to its upstream end (the source) or
  its downstream end (the exit). Every third cell, always ending at the end.
  """
  @spec path_along(t(), non_neg_integer(), :upstream | :downstream) :: [Space.cell()]
  def path_along(%__MODULE__{channel: channel}, index, direction) do
    last = tuple_size(channel) - 1
    indices = if direction == :upstream, do: index..0//-1, else: index..last//1
    finish = if direction == :upstream, do: 0, else: last

    indices
    |> Enum.take_every(3)
    |> Kernel.++([finish])
    |> Enum.dedup()
    |> Enum.map(&elem(channel, &1))
  end

  @doc "The compass direction the channel runs from `index`, upstream or downstream."
  @spec channel_direction(t(), non_neg_integer(), :upstream | :downstream) :: String.t() | nil
  def channel_direction(%__MODULE__{channel: channel}, index, direction) do
    last = tuple_size(channel) - 1
    toward = if direction == :upstream, do: max(index - 8, 0), else: min(index + 8, last)
    Space.direction(elem(channel, index), elem(channel, toward))
  end

  defp closest([], _cell), do: nil

  defp closest(points, cell) do
    {point, index} = Enum.min_by(points, fn {point, _index} -> Space.distance(point, cell) end)
    {index, point, Space.distance(point, cell)}
  end

  defp channel_elevation(%__MODULE__{lengths: lengths}, index) do
    total = elem(lengths, tuple_size(lengths) - 1)
    @source_elevation_m * (1 - elem(lengths, index) / total)
  end

  defp bank(distance) when distance <= @bed_half_width, do: -@bed_depth_m
  defp bank(distance), do: @bank_grade_m_per_cell * (distance - @bed_half_width)

  defp rises(%__MODULE__{rises: rises}, cell) do
    rises
    |> Enum.map(fn rise ->
      r = Space.distance(cell, rise.center) / rise.radius_cells
      rise.height_m * :math.exp(-r * r)
    end)
    |> Enum.sum()
  end

  # Smooth value noise on a coarse lattice, faded out near the channel so the
  # bed stays even.
  defp noise(%__MODULE__{} = terrain, {x, y} = cell) do
    fade =
      case nearest_channel(terrain, cell) do
        nil -> 1.0
        {_index, _point, distance} -> min(distance / 4, 1.0)
      end

    {gx, fx} = {div(x, @noise_scale), smooth(rem(x, @noise_scale) / @noise_scale)}
    {gy, fy} = {div(y, @noise_scale), smooth(rem(y, @noise_scale) / @noise_scale)}

    top = lerp(lattice(terrain.seed, gx, gy), lattice(terrain.seed, gx + 1, gy), fx)
    bottom = lerp(lattice(terrain.seed, gx, gy + 1), lattice(terrain.seed, gx + 1, gy + 1), fx)
    @noise_m * fade * lerp(top, bottom, fy)
  end

  defp lattice(seed, i, j), do: :erlang.phash2({seed, i, j}, 2_000_001) / 1_000_000 - 1.0
  defp smooth(t), do: t * t * (3 - 2 * t)
  defp lerp(a, b, t), do: a + (b - a) * t

  defp cumulative_lengths([]), do: []

  defp cumulative_lengths(channel) do
    lengths =
      channel
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.scan(0.0, fn [a, b], total -> total + Space.distance(a, b) end)

    [0.0 | lengths]
  end

  defp split_reaches(channel) when length(channel) < 2, do: []

  defp split_reaches(channel) do
    count = length(channel)

    0
    |> Range.new(count - 1, @reach_cells)
    |> Enum.map(fn first ->
      last = min(first + @reach_cells, count - 1)
      cells = Enum.slice(channel, first..last)

      %{
        first: first,
        last: last,
        mid: Enum.at(channel, div(first + last, 2)),
        length_m: max(Space.path_length(cells), 1.0) * Space.cell_size_m()
      }
    end)
    |> Enum.reject(&(&1.first == &1.last))
  end
end
