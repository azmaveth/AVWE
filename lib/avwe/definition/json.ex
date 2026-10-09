defmodule Avwe.Definition.Json do
  @moduledoc """
  JSON text for a world definition, from the data `Avwe.Definition.Codec`
  writes: maps with string keys, lists, strings, numbers, booleans and `nil`.
  Pure.

  `compact/1` is the canonical form, with no spaces and the keys in order: the
  same data is always the same text, however a file was laid out, and a
  definition's hash is taken over it. `pretty/1` is the form written to disk,
  for people to read and to review as a diff: one key to a line, `id` and
  `name` first, and whatever fits on a line (a cell, a date, a short list)
  left on one.
  """

  @width 88
  # Keys that name or date a thing come first, in this order, wherever they are.
  @first ~w(schema id name kind tagline description seed dt start rules entities miracles characters guests year day hour minute place verb target params)

  @doc "The canonical text: keys sorted, no spaces."
  @spec compact(term()) :: String.t()
  def compact(term), do: term |> compact_iodata() |> IO.iodata_to_binary()

  defp compact_iodata(%{} = map) do
    pairs =
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [scalar(key), ":", compact_iodata(value)] end)
      |> Enum.intersperse(",")

    ["{", pairs, "}"]
  end

  defp compact_iodata(list) when is_list(list),
    do: ["[", list |> Enum.map(&compact_iodata/1) |> Enum.intersperse(","), "]"]

  defp compact_iodata(scalar), do: scalar(scalar)

  @doc "The text for a file: indented, ending in a newline."
  @spec pretty(term()) :: String.t()
  def pretty(term), do: IO.iodata_to_binary([render(term, 0, 0), "\n"])

  # `taken` is what the line already holds beside the value: a key, a comma.
  defp render(value, level, taken) do
    line = flat(value)

    if String.length(line) + 2 * level + taken <= @width,
      do: line,
      else: expand(value, level)
  end

  defp expand(%{} = map, level) do
    inner = indent(level + 1)

    pairs =
      map
      |> entries()
      |> Enum.map(fn {key, value} ->
        key = IO.iodata_to_binary(scalar(key))
        [inner, key, ": ", render(value, level + 1, String.length(key) + 3)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", pairs, "\n", indent(level), "}"]
  end

  defp expand(list, level) when is_list(list) do
    inner = indent(level + 1)

    items =
      list
      |> Enum.map(&[inner, render(&1, level + 1, 1)])
      |> Enum.intersperse(",\n")

    ["[\n", items, "\n", indent(level), "]"]
  end

  defp expand(scalar, _level), do: scalar(scalar)

  defp flat(%{} = map) when map_size(map) == 0, do: "{}"

  defp flat(%{} = map) do
    pairs =
      Enum.map_join(entries(map), ", ", fn {key, value} -> [scalar(key), ": ", flat(value)] end)

    "{" <> pairs <> "}"
  end

  defp flat([]), do: "[]"
  defp flat(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &flat/1) <> "]"
  defp flat(scalar), do: IO.iodata_to_binary(scalar(scalar))

  # The keys that name a thing come first, in a fixed order; the rest follow
  # alphabetically.
  defp entries(map) do
    Enum.sort_by(map, fn {key, _value} ->
      case Enum.find_index(@first, &(&1 == key)) do
        nil -> {1, key}
        index -> {0, index}
      end
    end)
  end

  defp indent(level), do: String.duplicate("  ", level)

  # A float keeps its point, so it reads back a float (5000.0), and is written
  # out in full while that is short; a very large or small one in exponent
  # form (1.0e-5), which is also JSON.
  defp scalar(float) when is_float(float) do
    if float == Float.floor(float) and abs(float) < 1.0e15,
      do: Integer.to_string(trunc(float)) <> ".0",
      else: Float.to_string(float)
  end

  defp scalar(scalar), do: JSON.encode!(scalar)
end
