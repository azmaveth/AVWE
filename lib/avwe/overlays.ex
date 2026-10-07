defmodule Avwe.Overlays do
  @moduledoc """
  The fields a spectator's scene draws over the ground: the river by reach,
  the ground's heat, and the smoke. Pure, and derived: each is read from a
  snapshot (`Avwe.RegionServer.snapshot/2`: the region's changing state with
  its fields, and its terrain), and nothing is added to the region.

  ## Water

  One entry for each reach of the river, from the source to the exit: whether
  it has `silent` (fallen quiet, its depth under five centimetres), the
  water's `temp_c`, and whether it is `steaming` (warm banks in cold air,
  `Avwe.Systems.Heat`). Which cells are the reach's is the world ground's
  (`Avwe.WorldGround`), which does not change.

  ## Heat

  The ground's temperature in whole degrees, as rows over the whole map in the
  run-length code (`Avwe.Rle`): each stored cell is one letter for its level,
  `base` plus the letter's position (`a` is `base`, `b` is `base + step`, and
  so on up through `Z`: fifty-two levels, the last of them everything hotter),
  and `.` is a cell that is not stored. The heat system stores a cell only
  where it can differ from its neighbours (near the channel, on clay, at a
  hearth) and lets two backgrounds stand for all the rest, one for open grass
  and one for open stone; so a client draws a `.` cell in its ground's
  background, and the whole field is a few kilobytes and not a grid.

  ## Smoke

  The puffs, `[x, y, grams]`, the position to a tenth of a cell and the mass
  to two significant figures (whole grams from a hundred), in order.
  """

  alias Avwe.{Rle, Terrain}
  alias Avwe.Systems.{Heat, River}

  @base -10
  @step 1
  @alphabet "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @levels String.length(@alphabet)

  @type water :: [%{silent: boolean(), temp_c: float(), steaming: boolean()}]
  @type heat :: %{
          base: integer(),
          step: pos_integer(),
          air_c: float() | nil,
          backgrounds: %{grass: float() | nil, stone: float() | nil},
          rows: [String.t()]
        }
  @type smoke :: [[float()]]

  @doc "The river by reach, from the snapshot."
  @spec water(map()) :: water()
  def water(snapshot) do
    case get_in(snapshot, [:components, :river, River.id()]) do
      %{reaches: reaches} when is_tuple(reaches) ->
        heat = get_in(snapshot, [:fields, :heat])

        for k <- 0..(tuple_size(reaches) - 1)//1 do
          reach = elem(reaches, k)
          %{silent: reach.silent, temp_c: round1(reach.temp_c), steaming: steaming?(heat, k)}
        end

      _no_river ->
        []
    end
  end

  @doc "The ground's heat over the whole map, or `nil` for a world with none."
  @spec heat(map()) :: heat() | nil
  def heat(%{fields: %{heat: %Heat.Field{} = field}, terrain: %Terrain{} = terrain} = snapshot) do
    %{
      base: @base,
      step: @step,
      air_c: snapshot |> get_in([:env, :air_c]) |> round1(),
      backgrounds: %{grass: background(field, :grass), stone: background(field, :stone)},
      rows: rows(field, terrain.width, terrain.height)
    }
  end

  def heat(_snapshot), do: nil

  @doc """
  The level a temperature is drawn at: from 0, which is `base`, to 51, whatever
  is colder or hotter clamped to the ends.
  """
  @spec heat_level(number()) :: 0..51
  def heat_level(temp_c) do
    temp_c |> Kernel.-(@base) |> Kernel./(@step) |> round() |> max(0) |> min(@levels - 1)
  end

  @doc "The smoke's puffs, from the snapshot."
  @spec smoke(map()) :: smoke()
  def smoke(%{fields: %{smoke: %{puffs: puffs}}}) when is_list(puffs) do
    puffs
    |> Enum.filter(&(&1.g > 0))
    |> Enum.map(&[round1(&1.x), round1(&1.y), grams(&1.g)])
    |> Enum.sort()
  end

  def smoke(_snapshot), do: []

  # Water

  defp steaming?(%Heat.Field{} = field, k), do: Heat.steaming?(field, k)
  defp steaming?(_no_heat, _k), do: false

  # Heat

  defp background(field, ground) do
    case Map.fetch(field.index, {:background, ground}) do
      {:ok, i} -> field |> Heat.cell_c(i) |> round1()
      :error -> nil
    end
  end

  defp rows(field, width, height) do
    by_row =
      Enum.reduce(0..(tuple_size(field.static) - 1)//1, %{}, fn i, acc ->
        case elem(field.static, i) do
          %{cell: {x, y}} when is_integer(x) ->
            Map.update(acc, y, [{x, level(field, i)}], &[{x, level(field, i)} | &1])

          _background ->
            acc
        end
      end)

    for y <- 0..(height - 1), do: row(Map.get(by_row, y, []), width)
  end

  defp level(field, i), do: field |> Heat.cell_c(i) |> heat_level()

  defp row([], width), do: Rle.run(".", width)

  defp row(cells, width) do
    levels = Map.new(cells)
    {first, last} = levels |> Map.keys() |> Enum.min_max()

    middle =
      for x <- first..last do
        case Map.fetch(levels, x) do
          {:ok, level} -> binary_part(@alphabet, level, 1)
          :error -> "."
        end
      end

    IO.iodata_to_binary([Rle.run(".", first), Rle.encode(middle), Rle.run(".", width - 1 - last)])
  end

  # Smoke

  # Two significant figures, and whole grams from a hundred.
  defp grams(g) do
    digits = 1 - floor(:math.log10(g))
    Float.round(g * 1.0, digits |> max(0) |> min(15))
  end

  defp round1(nil), do: nil
  defp round1(number), do: Float.round(number * 1.0, 1)
end
