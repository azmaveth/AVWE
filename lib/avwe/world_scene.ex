defmodule Avwe.WorldScene do
  @moduledoc """
  What a spectator sees: the whole valley and everything in it, with its fields
  drawn over it. Pure, and derived: a snapshot goes in and nothing is added to
  the region, so the journal, the snapshots and `Avwe.Region.state_hash/1` are
  untouched.

  A body's scene (`Avwe.Scene`) is what one body can see, in a window around
  it. This is the other lens, and it holds no sight: a spectator "can see
  everything and cannot act" (DESIGN 9). The ground is not part of it, since it
  never changes: it is the world ground (`Avwe.WorldGround`), which a client
  is given once. What changes is here:

    * `time` - the world's time, for whoever draws it. It is not part of what
      makes one scene differ from another (`same_view?/2`).
    * `light` - from 0.0 to 1.0, to the nearest tenth, as the world's `env`
      has it: a client dims the valley by it.
    * `things` - every body, hearth and place in the world that is somewhere,
      sorted by kind and id. Each is `%{id, kind, cell, name, glyph}`, and a
      body adds `holder`: who holds it, or `nil` when its routine does.
    * `overlays` - `water`, `heat` and `smoke` (`Avwe.Overlays`).
    * `legend` - the layers (`Avwe.Repr`) of the kinds of thing in `things`.
      How each overlay is coloured is in `Avwe.Repr.overlay/1`, and `to_map/1`
      puts it beside the overlay's data.

  Like the body's scene, it is built from the world's own components, and
  names are canon, never a player's words.
  """

  alias Avwe.{Overlays, Repr, Space}

  @enforce_keys [:time]
  defstruct [
    :time,
    :light,
    things: [],
    overlays: %{water: [], heat: nil, smoke: []},
    legend: %{}
  ]

  @type thing :: %{
          required(:id) => String.t(),
          required(:kind) => Repr.thing(),
          required(:cell) => Space.cell(),
          required(:name) => String.t(),
          required(:glyph) => Repr.glyph(),
          optional(:holder) => term()
        }

  @type t :: %__MODULE__{
          time: integer(),
          light: float() | nil,
          things: [thing()],
          overlays: %{
            water: Overlays.water(),
            heat: Overlays.heat() | nil,
            smoke: Overlays.smoke()
          },
          legend: %{Repr.kind() => Repr.layers()}
        }

  @doc """
  The scene of a snapshot (`Avwe.RegionServer.snapshot/2`: the region's
  changing state, its fields and its terrain).
  """
  @spec build(map()) :: t()
  def build(%{components: components, time: time} = snapshot) do
    things = things(components)

    %__MODULE__{
      time: time,
      light: snapshot |> get_in([:env, :light]) |> light(),
      things: things,
      overlays: %{
        water: Overlays.water(snapshot),
        heat: Overlays.heat(snapshot),
        smoke: Overlays.smoke(snapshot)
      },
      legend: things |> Enum.map(& &1.kind) |> Repr.legend()
    }
  end

  @doc """
  Whether two scenes show the same thing: everything but the time. A client
  that only draws what has changed asks this.
  """
  @spec same_view?(t(), t()) :: boolean()
  def same_view?(%__MODULE__{} = a, %__MODULE__{} = b), do: %{a | time: nil} == %{b | time: nil}

  @doc """
  The scene as plain data any client can read: strings, numbers, lists and
  maps with string keys, so it goes to JSON as it is. A cell is `[x, y]`; a
  kind and a holder are strings (and `nil` stays `nil`). Each overlay carries
  its own layers (name, description, colours) beside its data, and an overlay a
  world has none of (a world with no terrain has no heat) is `nil`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scene) do
    %{
      "time" => scene.time,
      "light" => scene.light,
      "things" => Enum.map(scene.things, &thing_map/1),
      "legend" => Repr.legend_map(scene.legend),
      "overlays" => %{
        "water" =>
          Map.put(
            Repr.overlay_map(:water),
            "reaches",
            Enum.map(scene.overlays.water, &reach_map/1)
          ),
        "heat" => scene.overlays.heat && heat_map(scene.overlays.heat),
        "smoke" => Map.put(Repr.overlay_map(:smoke), "puffs", scene.overlays.smoke)
      }
    }
  end

  defp reach_map(reach) do
    %{"silent" => reach.silent, "temp_c" => reach.temp_c, "steaming" => reach.steaming}
  end

  defp heat_map(heat) do
    Map.merge(Repr.overlay_map(:heat), %{
      "base" => heat.base,
      "step" => heat.step,
      "air_c" => heat.air_c,
      "backgrounds" => %{
        "grass" => heat.backgrounds.grass,
        "stone" => heat.backgrounds.stone
      },
      "rows" => heat.rows
    })
  end

  defp thing_map(thing) do
    base = %{
      "id" => thing.id,
      "kind" => Atom.to_string(thing.kind),
      "cell" => cell(thing.cell),
      "name" => thing.name,
      "glyph" => Repr.glyph_map(thing.glyph)
    }

    if Map.has_key?(thing, :holder),
      do: Map.put(base, "holder", thing.holder && to_string(thing.holder)),
      else: base
  end

  defp cell({x, y}), do: [x, y]

  defp light(nil), do: 0.0
  defp light(light), do: Float.round(light * 1.0, 1)

  # Things

  defp things(components) do
    (bodies(components) ++ hearths(components) ++ places(components))
    |> Enum.sort_by(&{&1.kind, &1.id})
  end

  defp bodies(components) do
    for id <- ids(components, :body), cell = cell_of(components, id) do
      repr = get_in(components, [:repr, id])

      id
      |> thing(:body, cell, components, Repr.body_glyph(id, repr))
      |> Map.put(:holder, get_in(components, [:control, id, :holder]))
    end
  end

  defp hearths(components) do
    for id <- ids(components, :hearth), cell = cell_of(components, id) do
      kind = if components.hearth[id].burning, do: :hearth_burning, else: :hearth
      thing(id, kind, cell, components, Repr.glyph(kind))
    end
  end

  defp places(components) do
    for id <- ids(components, :place), cell = cell_of(components, id) do
      thing(id, :place, cell, components, Repr.glyph(:place))
    end
  end

  defp thing(id, kind, cell, components, glyph),
    do: %{id: id, kind: kind, cell: cell, name: name(components, id), glyph: glyph}

  defp ids(components, name), do: components |> Map.get(name, %{}) |> Map.keys() |> Enum.sort()
  defp cell_of(components, id), do: components |> Map.get(:position, %{}) |> Map.get(id)

  defp name(components, id) do
    case get_in(components, [:repr, id]) do
      %{name: name} when is_binary(name) -> name
      _no_name -> id
    end
  end
end
