defmodule Avwe.Scene do
  @moduledoc """
  What a body can see, as something a client can draw. Pure.

  `build/2` takes the view a session works on (`Avwe.Region.view/1` with the
  region's `:terrain` and the `:ground` map, `Avwe.GroundMap`) and a body, and
  returns:

    * `you` - the viewer: `id`, `name` and `glyph`.
    * `center` - the viewer's cell.
    * `radius` - how far it sees, in cells (`Avwe.Perception.sight_cells/1`, up
      to the next half cell, so it does not change every minute at dusk).
    * `light` - from 0.0 to 1.0, to the nearest tenth.
    * `origin` and `size` - the square window of cells that holds the circle of
      sight and everything shown: its north-west cell, and its side.
    * `rows` - the ground of each cell of the window, row by row from the north,
      each a run-length code (below), or `nil` when the world has no terrain.
    * `things` - what is in sight: bodies, hearths, fires seen from afar and
      the places the viewer knows. Each is `%{id, kind, cell, name, glyph}`.
    * `legend` - the layers (`Avwe.Repr`) of every kind the scene uses, and
      only those.
    * `holder` - who holds the viewer's body: its controller, or `nil` when
      its routine does.
    * `time` - the world's time, for whoever draws it. It is not part of what
      makes one scene differ from another (`same_view?/2`).

  **Nothing is drawn that the look does not say.** `things` is built from the
  look's own lists (`Avwe.Perception.look/2`: its `bodies`, `hearths`, `fires`
  and `places`, each with its `cell`), so a scene and the prose of a look can
  never disagree about who is there. Ground is drawn only inside the circle of
  sight, and cells outside it are blank. A fire shows from farther than the
  body sees (by its smoke or glow, at least 200 m), so the window grows to hold
  it, with blank ground around it.

  ## Rows

  A row is `size` cells, west to east, as runs of one letter and a count:
  `"g3s2.4"` is three grass, two silt and four cells that are not seen. The
  letters are `g` grass, `s` silt, `c` clay, `t` stone, `r` reeds, `b` the
  river bed, `w` water (a bed cell where the river runs) and `.` for blank.
  `kind_at/2` decodes one.
  """

  alias Avwe.{GroundMap, Perception, Repr, Rle, Space, Terrain}
  alias Avwe.Systems.River

  @letters %{
    "g" => :grass,
    "s" => :silt,
    "c" => :clay,
    "t" => :stone,
    "r" => :reeds,
    "b" => :channel_bed,
    "w" => :water
  }
  @by_byte {"g", "s", "c", "t", "r", "b"}
  @bed 5
  @blank "."

  @enforce_keys [:center, :radius, :origin, :size, :you]
  defstruct [
    :time,
    :light,
    :radius,
    :center,
    :origin,
    :size,
    :rows,
    :you,
    :holder,
    things: [],
    legend: %{}
  ]

  @type thing :: %{
          id: String.t(),
          kind: Repr.thing(),
          cell: Space.cell(),
          name: String.t() | nil,
          glyph: Repr.glyph()
        }

  @type t :: %__MODULE__{
          time: integer() | nil,
          light: float() | nil,
          radius: float(),
          center: Space.cell(),
          origin: Space.cell(),
          size: pos_integer(),
          rows: [String.t()] | nil,
          you: %{id: String.t(), name: String.t() | nil, glyph: Repr.glyph()},
          holder: term(),
          things: [thing()],
          legend: %{Repr.kind() => Repr.layers()}
        }

  @doc """
  The scene of `body` in `view`. `nil` for a spectator (`nil`, whose scene is
  a later slice) and for a body that is nowhere.
  """
  @spec build(map(), String.t() | nil) :: t() | nil
  def build(_view, nil), do: nil

  def build(view, body) do
    if get_in(view, [:components, :position, body]) == nil, do: nil, else: scene(view, body)
  end

  @doc """
  Whether two scenes show the same thing: everything but the time. A client
  that only draws what has changed asks this.
  """
  @spec same_view?(t(), t()) :: boolean()
  def same_view?(%__MODULE__{} = a, %__MODULE__{} = b), do: %{a | time: nil} == %{b | time: nil}

  @doc """
  The ground the scene shows at a cell: a kind (`Avwe.Repr.ground/0`), or
  `nil` for a cell that is blank, outside the window, or in a world with no
  terrain.
  """
  @spec kind_at(t(), Space.cell()) :: Repr.ground() | nil
  def kind_at(%__MODULE__{rows: nil}, _cell), do: nil

  def kind_at(%__MODULE__{origin: {ox, oy}, size: size, rows: rows}, {x, y})
      when x >= ox and x < ox + size and y >= oy and y < oy + size do
    rows |> Enum.at(y - oy) |> Rle.decode() |> Enum.at(x - ox) |> then(&Map.get(@letters, &1))
  end

  def kind_at(%__MODULE__{}, _cell), do: nil

  @doc """
  The scene as plain data any client can read: strings, numbers, lists and
  maps with string keys, so it goes to JSON as it is. A cell is `[x, y]`; a
  kind and the holder are strings (and `nil` stays `nil`).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scene) do
    %{
      "time" => scene.time,
      "light" => scene.light,
      "radius" => scene.radius,
      "center" => cell(scene.center),
      "origin" => cell(scene.origin),
      "size" => scene.size,
      "rows" => scene.rows,
      "you" => %{
        "id" => scene.you.id,
        "name" => scene.you.name,
        "glyph" => Repr.glyph_map(scene.you.glyph)
      },
      "holder" => scene.holder && to_string(scene.holder),
      "things" => Enum.map(scene.things, &thing_map/1),
      "legend" => Repr.legend_map(scene.legend)
    }
  end

  defp thing_map(thing) do
    %{
      "id" => thing.id,
      "kind" => Atom.to_string(thing.kind),
      "cell" => cell(thing.cell),
      "name" => thing.name,
      "glyph" => Repr.glyph_map(thing.glyph)
    }
  end

  defp cell({x, y}), do: [x, y]

  # The scene

  defp scene(view, body) do
    look = Perception.look(view, body)
    sight = Perception.sight_cells(look.light)
    radius = Float.ceil(sight * 2) / 2
    things = things(view, look, sight)
    center = look.cell
    half = max(ceil(radius), extent(things, center))
    {cx, cy} = center
    rows = rows(view[:ground], view, center, radius, half)
    repr = get_in(view, [:components, :repr, body])

    %__MODULE__{
      time: view.time,
      light: Float.round(look.light, 1),
      radius: radius,
      center: center,
      origin: {cx - half, cy - half},
      size: 2 * half + 1,
      rows: rows,
      you: %{id: body, name: look.body.name, glyph: Repr.body_glyph(body, repr)},
      holder: look.holder,
      things: things,
      legend: legend(rows, things)
    }
  end

  # How far, in cells along either axis, the farthest thing is from the viewer.
  defp extent(things, {cx, cy}) do
    things
    |> Enum.map(fn %{cell: {x, y}} -> max(abs(x - cx), abs(y - cy)) end)
    |> Enum.max(fn -> 0 end)
  end

  # Things

  defp things(view, look, sight) do
    (bodies(view, look) ++ hearths(look) ++ fires(look) ++ places(look, sight))
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp bodies(view, look) do
    for other <- look.bodies do
      repr = get_in(view, [:components, :repr, other.id])
      thing(other.id, :body, other, Repr.body_glyph(other.id, repr))
    end
  end

  defp hearths(look) do
    for hearth <- look.hearths do
      kind = if hearth.burning, do: :hearth_burning, else: :hearth
      thing(hearth.id, kind, hearth, Repr.glyph(kind))
    end
  end

  defp fires(look) do
    for fire <- look.fires, do: thing(fire.ref, fire.sign, fire, Repr.glyph(fire.sign))
  end

  # The places the viewer knows that are in sight, and the one it is at.
  defp places(look, sight) do
    here = if look.here, do: [look.here], else: []

    for place <- look.places ++ here, Space.distance(look.cell, place.cell) <= sight do
      thing(place.id, :place, place, Repr.glyph(:place))
    end
  end

  defp thing(id, kind, %{cell: cell} = source, glyph),
    do: %{id: id, kind: kind, cell: cell, name: source[:name], glyph: glyph}

  # The ground

  defp rows(%GroundMap{} = ground, view, {_cx, cy} = center, radius, half) do
    wet? = &wet?(view, &1)
    for dy <- -half..half, do: row(ground, wet?, center, radius, half, cy + dy, dy)
  end

  defp rows(_no_ground, _view, _center, _radius, _half), do: nil

  defp row(ground, wet?, {cx, _cy}, radius, half, y, dy) do
    # A row beyond the circle has no cell in it; the window may reach past the
    # circle to hold a fire seen from afar.
    reach =
      if dy * dy > radius * radius, do: -1, else: trunc(:math.sqrt(radius * radius - dy * dy))

    first = max(cx - reach, 0)
    last = min(cx + reach, ground.width - 1)

    if reach < 0 or y < 0 or y >= ground.height or first > last do
      blank(2 * half + 1)
    else
      segment = binary_part(ground.cells, y * ground.width + first, last - first + 1)

      IO.iodata_to_binary([
        blank(first - (cx - half)),
        segment |> codes(first, y, wet?, []) |> Rle.encode(),
        blank(cx + half - last)
      ])
    end
  end

  defp blank(count), do: Rle.run(@blank, count)

  defp codes(<<>>, _x, _y, _wet?, acc), do: Enum.reverse(acc)

  defp codes(<<@bed, rest::binary>>, x, y, wet?, acc),
    do: codes(rest, x + 1, y, wet?, [if(wet?.({x, y}), do: "w", else: "b") | acc])

  defp codes(<<byte, rest::binary>>, x, y, wet?, acc),
    do: codes(rest, x + 1, y, wet?, [elem(@by_byte, byte) | acc])

  # Whether the river runs at a bed cell: its reach is not silent.
  defp wet?(view, cell) do
    with %Terrain{} = terrain <- view[:terrain],
         %{reaches: reaches} when is_tuple(reaches) <-
           get_in(view, [:components, :river, River.id()]),
         {index, _point, _distance} <- Terrain.nearest_channel(terrain, cell),
         reach when reach < tuple_size(reaches) <- Terrain.reach_of(terrain, index) do
      match?(%{silent: false}, elem(reaches, reach))
    else
      _dry -> false
    end
  end

  # The layers of what the scene uses.
  defp legend(rows, things) do
    ground =
      (rows || [])
      |> Enum.join()
      |> String.graphemes()
      |> Enum.flat_map(&List.wrap(Map.get(@letters, &1)))

    Repr.legend(ground ++ Enum.map(things, & &1.kind))
  end
end
