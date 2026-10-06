defmodule Avwe.ReprTest do
  use ExUnit.Case, async: true

  alias Avwe.Repr

  @ground ~w(channel_bed reeds clay silt stone grass water)a
  @things ~w(body hearth hearth_burning place smoke glow)a

  describe "the kinds" do
    test "include every kind of ground the terrain can name, and water, and each thing a scene shows" do
      assert Repr.kinds() == Enum.sort(@ground ++ @things)
    end

    test "each has a name, a description and a glyph a client can draw" do
      for kind <- Repr.kinds() do
        layers = Repr.layers(kind)
        assert is_binary(layers.name) and layers.name != "", inspect(kind)
        assert is_binary(layers.description) and layers.description != "", inspect(kind)
        assert Repr.valid_char?(layers.glyph.char), inspect(kind)
        assert Repr.valid_color?(layers.glyph.color), inspect(kind)
        assert Repr.glyph(kind) == layers.glyph
      end
    end

    test "are told apart by their characters, not by colour alone" do
      chars = Enum.map(Repr.kinds(), &Repr.glyph(&1).char)
      assert length(Enum.uniq(chars)) == length(chars)
    end

    test "form a legend of just the kinds asked for, once each" do
      legend = Repr.legend([:grass, :body, :grass, :water])
      assert Map.keys(legend) |> Enum.sort() == [:body, :grass, :water]
      assert legend.grass == Repr.layers(:grass)
      assert Repr.legend([]) == %{}
    end
  end

  describe "a body's glyph" do
    test "is its own when its world gave it one" do
      own = %{char: "M", color: "#e8c07a"}
      assert Repr.body_glyph("mira-vale", %{name: "Mira Vale", glyph: own}) == own
    end

    test "is otherwise an @ in a colour taken from its id: the same every time, and often not the same as another's" do
      first = Repr.body_glyph("mira-vale", %{name: "Mira Vale"})
      assert first.char == "@"
      assert Repr.valid_color?(first.color)
      assert Repr.body_glyph("mira-vale", nil) == first

      colours = for id <- ~w(wren pell tamsin odo mira-vale), do: Repr.body_glyph(id, nil).color
      assert length(Enum.uniq(colours)) > 1
    end
  end

  describe "override!/3" do
    @default %{char: "@", color: "#e8d9a0"}

    test "is nil when the world gave neither a glyph nor a color" do
      assert Repr.override!([routine: []], @default, "character \"a\"") == nil
    end

    test "takes what was given and keeps the default for what was not" do
      assert Repr.override!([glyph: "M"], @default, "x") == %{char: "M", color: "#e8d9a0"}
      assert Repr.override!([color: "#112233"], @default, "x") == %{char: "@", color: "#112233"}

      assert Repr.override!([glyph: "é", color: "#AbCdEf"], @default, "x") ==
               %{char: "é", color: "#AbCdEf"}
    end

    test "raises, naming what it was for, for a glyph that is not one printable character" do
      for bad <- ["", "ab", " ", "\n", "\e", "\u200B", "a\u200Db", 5, :m, ["a"]] do
        assert_raise ArgumentError,
                     ~r/^character "mira": glyph must be one printable character/,
                     fn ->
                       Repr.override!([glyph: bad], @default, "character \"mira\"")
                     end
      end
    end

    test "raises for a color that is not #rrggbb" do
      for bad <- ["red", "#fff", "#12345", "#1234567", "112233", "#gggggg", 0x112233, :red] do
        assert_raise ArgumentError, ~r/^character "mira": color must be #rrggbb/, fn ->
          Repr.override!([color: bad], @default, "character \"mira\"")
        end
      end
    end
  end
end
