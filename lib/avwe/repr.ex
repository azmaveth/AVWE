defmodule Avwe.Repr do
  @moduledoc """
  What things look like, layer by layer. Pure.

  Every entity has a `repr`: a name and a description. DESIGN 8.4 promises the
  rest of the layers, `name → description → glyph (char + color) → sprite
  (asset key) → model`, so that a client uses the richest one it understands
  and an older client can still show something. This module holds the glyph
  layer for each kind of thing a scene (`Avwe.Scene`) can show. A sprite
  layer will be a `sprite:` key beside `glyph:` in the same maps, and a
  client that does not know it ignores it.

  A *kind* is what sort of thing it is, not which one: the ground kinds
  (`Avwe.Terrain.ground/0`, plus `:water` for a channel cell where the river
  runs) and the things on it. A body, which is one of many, has its own glyph:
  `body_glyph/2`.

  A glyph is one character, which a client draws in a color: `%{char: "@",
  color: "#e8d9a0"}`. A world's configuration may give a character its own
  (`glyph:` and `color:` beside `routine:`, see `Avwe.Worldgen`); `override!/3`
  checks them when the world is built, as the rest of the configuration is.
  """

  alias Avwe.Terrain

  @type ground :: Terrain.ground() | :water
  @type thing :: :body | :hearth | :hearth_burning | :place | :smoke | :glow
  @type kind :: ground() | thing()
  @type glyph :: %{char: String.t(), color: String.t()}
  @type layers :: %{name: String.t(), description: String.t(), glyph: glyph()}

  @layers %{
    grass: %{
      name: "grass",
      description: "Dry grass.",
      glyph: %{char: "\"", color: "#6f8f4a"}
    },
    silt: %{
      name: "silt",
      description: "Pale, fine silt, the old river's banks.",
      glyph: %{char: ".", color: "#b8a070"}
    },
    clay: %{
      name: "clay",
      description: "Packed clay, the town's streets.",
      glyph: %{char: ":", color: "#b0653a"}
    },
    stone: %{
      name: "stone",
      description: "Pale stone breaking through thin soil.",
      glyph: %{char: "^", color: "#9a9a9a"}
    },
    reeds: %{
      name: "reeds",
      description: "Reeds that keep the channel's shape.",
      glyph: %{char: "|", color: "#9aa84a"}
    },
    channel_bed: %{
      name: "dry river bed",
      description: "Cracked mud where the river ran.",
      glyph: %{char: "_", color: "#7a6850"}
    },
    water: %{
      name: "water",
      description: "The river, running.",
      glyph: %{char: "~", color: "#3b82c4"}
    },
    body: %{
      name: "person",
      description: "Somebody.",
      glyph: %{char: "@", color: "#e8d9a0"}
    },
    hearth: %{
      name: "cold hearth",
      description: "A hearth with no fire in it.",
      glyph: %{char: "o", color: "#8a8078"}
    },
    hearth_burning: %{
      name: "burning hearth",
      description: "A hearth with a fire in it.",
      glyph: %{char: "*", color: "#ff9a3c"}
    },
    place: %{
      name: "place",
      description: "A place you know.",
      glyph: %{char: "#", color: "#d8c8a8"}
    },
    smoke: %{
      name: "smoke",
      description: "Smoke rising from a fire in the distance.",
      glyph: %{char: "%", color: "#b0b0b0"}
    },
    glow: %{
      name: "glow",
      description: "The glow of a fire in the distance.",
      glyph: %{char: "+", color: "#ffb84d"}
    }
  }

  # What two bodies in a scene are told apart by when nobody has chosen.
  @body_palette ~w(#e8d9a0 #e8a07a #a0c8e8 #c8e8a0 #e8a0c8 #a0e8d0 #d0a0e8 #e8e8a0)

  @color ~r/\A#[0-9a-fA-F]{6}\z/
  @one_character ~r/\A[\p{L}\p{N}\p{P}\p{S}]\p{M}*\z/u

  @doc "Every kind there is a layer for."
  @spec kinds() :: [kind()]
  def kinds, do: @layers |> Map.keys() |> Enum.sort()

  @doc "The layers of one kind."
  @spec layers(kind()) :: layers()
  def layers(kind), do: Map.fetch!(@layers, kind)

  @doc "The glyph of one kind."
  @spec glyph(kind()) :: glyph()
  def glyph(kind), do: layers(kind).glyph

  @doc """
  The layers of each of `kinds`, keyed by kind: what a scene lists so that a
  client need not know the kinds in advance.
  """
  @spec legend([kind()]) :: %{kind() => layers()}
  def legend(kinds), do: kinds |> Enum.uniq() |> Map.new(&{&1, layers(&1)})

  @doc """
  The glyph of the body `id`, whose entity's `repr` is `repr`: the one its
  world gave it, else an `@` in a color taken from `id`, so the same body is
  always the same color and two bodies in sight are usually told apart.
  """
  @spec body_glyph(String.t(), map() | nil) :: glyph()
  def body_glyph(_id, %{glyph: %{char: _char, color: _color} = glyph}), do: glyph

  def body_glyph(id, _repr) do
    color = Enum.at(@body_palette, :erlang.phash2(id, length(@body_palette)))
    %{glyph(:body) | color: color}
  end

  @doc """
  The glyph a world's configuration gives something, from its `:glyph` and
  `:color`, either of which may be left out (a missing one is `default`'s), or
  `nil` when it gives neither. A character that is not one printable
  character, or a color that is not `#rrggbb`, raises `ArgumentError` naming
  `what`, so a bad value is found when the world is built, not when it is
  first drawn.
  """
  @spec override!(keyword(), glyph(), String.t()) :: glyph() | nil
  def override!(spec, default, what) do
    char = Keyword.get(spec, :glyph)
    color = Keyword.get(spec, :color)

    if char == nil and color == nil do
      nil
    else
      %{
        char: if(char == nil, do: default.char, else: char!(char, what)),
        color: if(color == nil, do: default.color, else: color!(color, what))
      }
    end
  end

  @doc "Whether `char` is one printable character, which a glyph may be."
  @spec valid_char?(term()) :: boolean()
  def valid_char?(char), do: is_binary(char) and String.valid?(char) and char =~ @one_character

  @doc "Whether `color` is a color a glyph may have: `#` and six hexadecimal digits."
  @spec valid_color?(term()) :: boolean()
  def valid_color?(color), do: is_binary(color) and color =~ @color

  defp char!(char, what) do
    if valid_char?(char),
      do: char,
      else:
        raise(
          ArgumentError,
          "#{what}: glyph must be one printable character, got #{inspect(char)}"
        )
  end

  defp color!(color, what) do
    if valid_color?(color),
      do: color,
      else: raise(ArgumentError, "#{what}: color must be #rrggbb, got #{inspect(color)}")
  end
end
