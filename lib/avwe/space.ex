defmodule Avwe.Space do
  @moduledoc """
  Geometry on the world grid. A cell is 10 m on a side; x grows to the east
  and y grows to the south.
  """

  @cell_m 10
  @directions ~w(north north-east east south-east south south-west west north-west)

  @type cell :: {integer(), integer()}

  @doc "Metres per cell."
  @spec cell_size_m() :: pos_integer()
  def cell_size_m, do: @cell_m

  @doc "Straight-line distance between two cells, in cells."
  @spec distance(cell(), cell()) :: float()
  def distance({x1, y1}, {x2, y2}), do: :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)

  @doc "A distance in cells as metres, rounded to the nearest 10 m."
  @spec meters(number()) :: non_neg_integer()
  def meters(cells), do: round(cells) * @cell_m

  @doc """
  The compass direction from one cell to another, such as `"north-east"`, or
  `nil` when they are the same cell.
  """
  @spec direction(cell(), cell()) :: String.t() | nil
  def direction(same, same), do: nil

  def direction({x1, y1}, {x2, y2}) do
    degrees = :math.atan2(x2 - x1, y1 - y2) * 180 / :math.pi()
    Enum.at(@directions, rem(round(degrees / 45) + 8, 8))
  end

  @doc "The cell a fraction `t` of the way from one cell to another."
  @spec lerp(cell(), cell(), float()) :: cell()
  def lerp({x1, y1}, {x2, y2}, t), do: {round(x1 + (x2 - x1) * t), round(y1 + (y2 - y1) * t)}

  @doc "The eight compass directions, clockwise from north."
  @spec directions() :: [String.t()]
  def directions, do: @directions

  @doc """
  The cell `cells` away from `cell` in a compass direction, kept inside a
  square map of `size` cells.
  """
  @spec offset(cell(), String.t(), number(), pos_integer()) :: cell()
  def offset({x, y}, direction, cells, size) do
    index = Enum.find_index(@directions, &(&1 == direction))
    radians = index * :math.pi() / 4
    to = {round(x + :math.sin(radians) * cells), round(y - :math.cos(radians) * cells)}
    clamp(to, size)
  end

  @doc "Keeps a cell inside a square map of `size` cells."
  @spec clamp(cell(), pos_integer()) :: cell()
  def clamp({x, y}, size), do: {x |> max(0) |> min(size - 1), y |> max(0) |> min(size - 1)}

  @doc "The length of a path through `points`, in cells."
  @spec path_length([cell()]) :: float()
  def path_length(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> distance(a, b) end)
    |> Enum.sum()
  end

  @doc "The cell `covered` cells along a path through `points`."
  @spec along([cell(), ...], number()) :: cell()
  def along([point], _covered), do: point

  def along([a, b | rest], covered) do
    leg = distance(a, b)

    if covered <= leg and leg > 0,
      do: lerp(a, b, covered / leg),
      else: along([b | rest], covered - leg)
  end
end
