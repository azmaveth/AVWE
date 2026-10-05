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
end
