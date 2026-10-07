defmodule Avwe.Test.PageData do
  @moduledoc """
  What a watch page gives its canvas, read as a test of the river and its banks
  needs it: the ground (`data-ground`, `Avwe.WorldGround.to_map/1`) and the scene
  (`data-scene`, `Avwe.WorldScene.to_map/1`) as the page parses them, plain data
  with string keys. They come from the attributes of a page of
  `Phoenix.LiveViewTest` (`scene/1`, `ground/1`), from the browser, or straight
  from the server's own `to_map/1`.

  The colours are worked out here a second time, from the scene's own ramp and
  the same arithmetic the page's script uses (`assets/js/world.js`), so that a
  test can say what a canvas should show at a cell and not only that it shows
  something.
  """

  import Phoenix.LiveViewTest, only: [element: 2, render: 1]

  alias Avwe.Rle

  @levels "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  @doc "What the page gave its canvas in the attribute `name`, parsed."
  @spec attribute(Phoenix.LiveViewTest.View.t(), String.t()) :: map()
  def attribute(view, name) do
    view
    |> element("#world")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> hd()
    |> Jason.decode!()
  end

  @doc "The scene the page gave its canvas."
  @spec scene(Phoenix.LiveViewTest.View.t()) :: map()
  def scene(view), do: attribute(view, "data-scene")

  @doc "The ground the page gave its canvas."
  @spec ground(Phoenix.LiveViewTest.View.t()) :: map()
  def ground(view), do: attribute(view, "data-ground")

  @doc "Whether each reach of the river, from the source down, is silent."
  @spec silent(map()) :: [boolean()]
  def silent(scene), do: for(reach <- scene["overlays"]["water"]["reaches"], do: reach["silent"])

  @doc "Whether each reach of the river, from the source down, steams."
  @spec steaming(map()) :: [boolean()]
  def steaming(scene) do
    for reach <- scene["overlays"]["water"]["reaches"], do: reach["steaming"]
  end

  @doc "The cells whose ground is `letter` (s is silt, b the river's bed), as `{x, y}`."
  @spec cells(map(), String.t()) :: [{integer(), integer()}]
  def cells(ground, letter) do
    for {row, y} <- ground["rows"] |> Enum.map(&Rle.decode/1) |> Enum.with_index(),
        {^letter, x} <- Enum.with_index(row),
        do: {x, y}
  end

  @doc """
  The level the heat overlay draws each of `cells` at (a letter of fifty-two
  levels, a degree each), left out for a cell it does not store.
  """
  @spec levels(map(), [{integer(), integer()}]) :: %{{integer(), integer()} => non_neg_integer()}
  def levels(scene, cells) do
    rows =
      scene["overlays"]["heat"]["rows"] |> Enum.map(&Rle.decode/1) |> Enum.map(&List.to_tuple/1)

    for {x, y} <- cells,
        symbol = rows |> Enum.at(y) |> elem(x),
        symbol != ".",
        into: %{} do
      {{x, y}, @levels |> :binary.match(symbol) |> elem(0)}
    end
  end

  @doc "The mean level the heat overlay draws `cells` at, over those it stores."
  @spec mean_level(map(), [{integer(), integer()}]) :: float()
  def mean_level(scene, cells) do
    levels = scene |> levels(cells) |> Map.values()
    Enum.sum(levels) / length(levels)
  end

  @doc """
  The colour of a level on the heat's ramp, as `{r, g, b}`: the end colour for
  a temperature beyond the ramp, and a mix of the two stops either side of it
  between, each channel rounded.
  """
  @spec heat_rgb(map(), non_neg_integer()) :: {0..255, 0..255, 0..255}
  def heat_rgb(scene, level) do
    %{"base" => base, "step" => step, "ramp" => ramp} = scene["overlays"]["heat"]
    temperature = base + step * level
    [first | _] = ramp
    last = List.last(ramp)

    cond do
      temperature <= first["at"] -> rgb(first["color"])
      temperature >= last["at"] -> rgb(last["color"])
      true -> mix(ramp, temperature)
    end
  end

  defp mix(ramp, temperature) do
    upper = Enum.find_index(ramp, &(&1["at"] >= temperature))
    {low, high} = {Enum.at(ramp, upper - 1), Enum.at(ramp, upper)}
    t = (temperature - low["at"]) / (high["at"] - low["at"])
    {r1, g1, b1} = rgb(low["color"])
    {r2, g2, b2} = rgb(high["color"])
    {round(r1 + (r2 - r1) * t), round(g1 + (g2 - g1) * t), round(b1 + (b2 - b1) * t)}
  end

  @doc "A colour written `#rrggbb`, as `{r, g, b}`."
  @spec rgb(String.t()) :: {0..255, 0..255, 0..255}
  def rgb("#" <> hex) do
    <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  @doc """
  What a canvas shows at a cell with the heat drawn over it, when it showed
  `under` without: the heat at four fifths opacity over what was there.
  """
  @spec heat_over({0..255, 0..255, 0..255}, {0..255, 0..255, 0..255}) ::
          {0..255, 0..255, 0..255}
  def heat_over({hr, hg, hb}, {ur, ug, ub}) do
    {blend(hr, ur), blend(hg, ug), blend(hb, ub)}
  end

  defp blend(heat, under), do: round(heat * 0.8 + under * 0.2)

  @doc """
  A sample of the bed's cells, one for each reach, that nothing is drawn over but
  the river: the middle cell of the reach out of those at least `apart` cells
  from every thing in the scene.
  """
  @spec bed_samples(map(), map(), pos_integer()) :: [{integer(), integer()}]
  def bed_samples(ground, scene, apart \\ 4) do
    things = for thing <- scene["things"], do: List.to_tuple(thing["cell"])

    for reach <- ground["reaches"] do
      cells = for [x, y] <- reach, do: {x, y}
      clear = Enum.reject(cells, &near?(&1, things, apart))
      clear |> Enum.at(div(length(clear), 2)) |> Kernel.||(Enum.at(cells, div(length(cells), 2)))
    end
  end

  @doc """
  A sample of `count` silt cells that nothing is drawn over but the heat: not
  within two cells of the river's bed (where the haze of steam falls), nor within
  `apart` of a thing, and stored by the heat overlay; evenly spread along the
  banks, in reading order.
  """
  @spec bank_samples(map(), map(), pos_integer(), pos_integer()) :: [{integer(), integer()}]
  def bank_samples(ground, scene, count, apart \\ 4) do
    things = for thing <- scene["things"], do: List.to_tuple(thing["cell"])
    bed = cells(ground, "b")
    silt = cells(ground, "s")
    stored = scene |> levels(silt) |> Map.keys() |> MapSet.new()

    candidates =
      for cell <- silt,
          cell in stored,
          not near?(cell, bed, 2),
          not near?(cell, things, apart),
          do: cell

    step = max(div(length(candidates), count), 1)
    candidates |> Enum.take_every(step) |> Enum.take(count)
  end

  defp near?({x, y}, cells, apart) do
    Enum.any?(cells, fn {cx, cy} -> max(abs(cx - x), abs(cy - y)) < apart end)
  end
end
