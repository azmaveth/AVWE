defmodule Avwe.Rle do
  @moduledoc """
  The run-length code of a row of cells, as a scene sends it. Pure.

  A row is a letter and a count for each run: `"g3s2.4"` is three `g`, two `s`
  and four `.`. A symbol is one letter or a dot, and a count is the decimal
  number of cells, one or more. A client decodes it with a scan for
  `([a-zA-Z.])(\\d+)`, so nothing else may appear in a code.
  """

  @doc "The code of `symbols`, a list of one-character strings, as an iolist."
  @spec encode([String.t()]) :: iolist()
  def encode([]), do: []
  def encode([symbol | rest]), do: encode(rest, symbol, 1, [])

  defp encode([], symbol, count, acc), do: Enum.reverse([Integer.to_string(count), symbol | acc])
  defp encode([symbol | rest], symbol, count, acc), do: encode(rest, symbol, count + 1, acc)

  defp encode([other | rest], symbol, count, acc),
    do: encode(rest, other, 1, [Integer.to_string(count), symbol | acc])

  @doc "The symbols a code stands for, one for each cell."
  @spec decode(String.t()) :: [String.t()]
  def decode(code) do
    for [_run, symbol, count] <- Regex.scan(~r/([a-zA-Z.])(\d+)/, code),
        _cell <- 1..String.to_integer(count)//1,
        do: symbol
  end

  @doc "The code of `count` cells of one `symbol`, as a string."
  @spec run(String.t(), non_neg_integer()) :: String.t()
  def run(_symbol, 0), do: ""
  def run(symbol, count), do: symbol <> Integer.to_string(count)
end
