defmodule Avwe.RleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.Rle

  defp code(symbols), do: symbols |> Rle.encode() |> IO.iodata_to_binary()

  describe "encode/1" do
    test "gives a letter and a count for each run" do
      assert code(~w(g g g s s . . . .)) == "g3s2.4"
    end

    test "keeps a run of one, and runs that come back" do
      assert code(~w(g s g)) == "g1s1g1"
    end

    test "is nothing for nothing" do
      assert code([]) == ""
    end

    test "counts of any length, and capital letters" do
      assert code(List.duplicate("A", 256)) == "A256"
    end
  end

  describe "decode/1" do
    test "gives a symbol for each cell" do
      assert Rle.decode("g3s2.4") == ~w(g g g s s . . . .)
    end

    test "is nothing for nothing" do
      assert Rle.decode("") == []
    end
  end

  describe "run/2" do
    test "is a symbol and a count, and nothing for no cells" do
      assert Rle.run(".", 12) == ".12"
      assert Rle.run(".", 0) == ""
    end
  end

  property "decoding what was encoded gives the cells back" do
    symbol = StreamData.member_of(String.graphemes("abcdefXYZ."))

    check all(cells <- StreamData.list_of(symbol, max_length: 300)) do
      assert cells |> code() |> Rle.decode() == cells
    end
  end

  property "a code has no two runs of one symbol in a row" do
    symbol = StreamData.member_of(~w(a b .))

    check all(cells <- StreamData.list_of(symbol, min_length: 1, max_length: 100)) do
      symbols = ~r/([a-zA-Z.])\d+/ |> Regex.scan(code(cells)) |> Enum.map(&List.last/1)
      assert symbols == Enum.dedup(symbols)
    end
  end
end
