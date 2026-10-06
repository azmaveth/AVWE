defmodule Avwe.GroundMap do
  @moduledoc """
  The ground of every cell of a map, as one compact binary. Pure.

  Terrain is a small description, and `Avwe.Terrain.ground/2` works out any
  cell's ground from it on demand, at about 16 microseconds a cell. That is
  fine for one cell and far too slow for a window of ten thousand every step,
  so a client that draws asks for the whole map once (`Avwe.Terrain.ground_map/1`,
  about a second for the 256 by 256 Ember Reach) and reads cells from it
  (`at/2`, `slice/4`).

  Derived data, not state: nothing here is part of a region, snapshotted or
  hashed, and the same terrain always gives the same map.

  One byte a cell, row by row, west to east and north to south, so the cell
  `{x, y}` is byte `y * width + x`. The byte is the position of its ground
  in `kinds/0`.
  """

  @kinds [:grass, :silt, :clay, :stone, :reeds, :channel_bed]

  @enforce_keys [:width, :height, :cells]
  defstruct [:width, :height, :cells]

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer(), cells: binary()}

  @doc "The grounds a map holds, in the order of their bytes."
  @spec kinds() :: [Avwe.Terrain.ground()]
  def kinds, do: @kinds

  @doc "The byte for a ground."
  @spec code(Avwe.Terrain.ground()) :: 0..5
  for {kind, code} <- Enum.with_index(@kinds) do
    def code(unquote(kind)), do: unquote(code)
  end

  @doc "The ground for a byte, or `nil` for one that is none."
  @spec kind(byte()) :: Avwe.Terrain.ground() | nil
  def kind(code), do: Enum.at(@kinds, code)

  @doc """
  A map `width` cells across and `height` down, from its `cells`, one byte
  each. Raises `ArgumentError` if there are not exactly that many.
  """
  @spec new(pos_integer(), pos_integer(), binary()) :: t()
  def new(width, height, cells) when width > 0 and height > 0 and is_binary(cells) do
    if byte_size(cells) != width * height do
      raise ArgumentError,
            "a #{width} by #{height} ground map takes #{width * height} cells, " <>
              "got #{byte_size(cells)}"
    end

    %__MODULE__{width: width, height: height, cells: cells}
  end

  @doc "The ground of a cell, or `nil` for one off the map."
  @spec at(t(), Avwe.Space.cell()) :: Avwe.Terrain.ground() | nil
  def at(%__MODULE__{width: width, height: height, cells: cells}, {x, y})
      when x >= 0 and x < width and y >= 0 and y < height do
    cells |> binary_part(y * width + x, 1) |> :binary.first() |> kind()
  end

  def at(%__MODULE__{}, _cell), do: nil

  @doc """
  The grounds of row `y` from column `x` for `count` cells, as a list: a
  piece of a row for a client to draw. Cells beyond the map are `nil`, so the
  list is always `count` long.
  """
  @spec slice(t(), integer(), integer(), non_neg_integer()) :: [Avwe.Terrain.ground() | nil]
  def slice(%__MODULE__{} = map, y, x, count),
    do: for(dx <- 0..(count - 1)//1, do: at(map, {x + dx, y}))
end
