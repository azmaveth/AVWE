defmodule Avwe.WorldGround do
  @moduledoc """
  The ground of the whole map, as a spectator's page draws it. Pure.

  A spectator sees the whole valley, so its ground is the whole map, and it
  never changes for a terrain: built once (`Avwe.GroundCache.world/1`), and a
  client is given it once, not with each scene.

    * `width` and `height`, in cells.
    * `rows` - every row, north to south, as a run-length code
      (`Avwe.Rle`) of the letters a body's scene uses: `g` grass, `s` silt, `c`
      clay, `t` stone, `r` reeds and `b` the river's bed. A bed cell is always
      `b`, never `w`: whether the river runs there is the water overlay's to say
      (`Avwe.Overlays`), so the ground is not sent again when a reach falls
      silent.
    * `reaches` - for each reach of the river, from the source to the exit, the
      cells of its bed in reading order, so that a client can draw them wet or
      dry from the water overlay alone. A bed cell belongs to the reach of the
      channel point nearest it, as it does in a body's scene.

  Derived data, as the ground map is: not state, not snapshotted, not hashed.
  """

  alias Avwe.{GroundMap, Rle, Space, Terrain}

  @enforce_keys [:width, :height, :rows, :reaches]
  defstruct [:width, :height, :rows, :reaches]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          rows: [String.t()],
          reaches: [[Space.cell()]]
        }

  # The letter of each byte of a ground map, in the order of `GroundMap.kinds/0`.
  @letters {"g", "s", "c", "t", "r", "b"}
  @bed GroundMap.code(:channel_bed)

  @doc "The world ground of `terrain`, from its ground map."
  @spec build(Terrain.t(), GroundMap.t()) :: t()
  def build(%Terrain{} = terrain, %GroundMap{width: width, height: height, cells: cells}) do
    %__MODULE__{
      width: width,
      height: height,
      rows: for(y <- 0..(height - 1), do: row(cells, width, y)),
      reaches: reaches(terrain, cells, width, height)
    }
  end

  @doc """
  The ground as plain data any client can read: strings, numbers, lists, maps
  with string keys; a cell is `[x, y]`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ground) do
    %{
      "width" => ground.width,
      "height" => ground.height,
      "rows" => ground.rows,
      "reaches" => for(cells <- ground.reaches, do: for({x, y} <- cells, do: [x, y]))
    }
  end

  defp row(cells, width, y) do
    cells
    |> binary_part(y * width, width)
    |> :binary.bin_to_list()
    |> Enum.map(&elem(@letters, &1))
    |> Rle.encode()
    |> IO.iodata_to_binary()
  end

  defp reaches(terrain, cells, width, height) do
    by_reach =
      for y <- 0..(height - 1),
          x <- 0..(width - 1),
          :binary.at(cells, y * width + x) == @bed,
          reach = reach_of(terrain, {x, y}),
          reduce: %{} do
        acc -> Map.update(acc, reach, [{x, y}], &[{x, y} | &1])
      end

    for reach <- 0..(length(Terrain.reaches(terrain)) - 1)//1 do
      by_reach |> Map.get(reach, []) |> Enum.reverse()
    end
  end

  defp reach_of(terrain, cell) do
    case Terrain.nearest_channel(terrain, cell) do
      {index, _point, _distance} -> Terrain.reach_of(terrain, index)
      nil -> nil
    end
  end
end
