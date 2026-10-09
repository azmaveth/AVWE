defmodule Avwe.Test.Boundary do
  @moduledoc """
  What a source file refers to, read from its code: every module of the `Avwe`
  namespace named in it, aliases resolved. For the tests that keep the
  simulation kernel from naming what lives above it (`test/avwe/kernel_test.exs`):
  a file that names a module names it in code, in a type or in a spec, where
  the beam file would not show it. Documentation strings are not code and are
  not read.
  """

  @doc "The `Avwe` modules the code of `path` refers to, by name (`\"Avwe.Region\"`)."
  @spec references(Path.t()) :: MapSet.t(String.t())
  def references(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    aliases = ast |> collect(&alias_of/1) |> Map.new()

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        # An alias declares a name; it is not a reference until it is used.
        {:alias, _meta, _args}, acc -> {:ok, acc}
        node, acc -> {node, [reference(node, aliases) | acc]}
      end)

    found |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  @doc "The words of `list` that `path` uses, as whole words in code or documentation."
  @spec words(Path.t(), [String.t()]) :: [String.t()]
  def words(path, list) do
    text = File.read!(path)

    Enum.filter(list, fn word -> Regex.match?(~r/\b#{word}\b/i, text) end)
  end

  defp collect(ast, fun) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case fun.(node) do
          nil -> {node, acc}
          :skip -> {node, acc}
          found -> {node, List.wrap(found) ++ acc}
        end
      end)

    acc
  end

  # `alias A.B`, `alias A.B, as: C` and `alias A.{B, C}`, as {last_name, module}.
  defp alias_of({:alias, _meta, [{:__aliases__, _, parts}]}),
    do: [{List.last(parts), concat(parts)}]

  defp alias_of({:alias, _meta, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [name]}]]}),
    do: [{name, concat(parts)}]

  defp alias_of({:alias, _meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, group}]}) do
    for {:__aliases__, _, parts} <- group, do: {List.last(parts), concat(base ++ parts)}
  end

  defp alias_of(_node), do: nil

  # A name in the `Avwe` namespace, or an alias that stands for one.
  defp reference({:__aliases__, _meta, [:Avwe | _rest] = parts}, _aliases), do: concat(parts)

  defp reference({:__aliases__, _meta, [first | rest]}, aliases) when is_atom(first) do
    case aliases do
      %{^first => module} -> Enum.join([module | Enum.map(rest, &to_string/1)], ".")
      _none -> nil
    end
  end

  defp reference(_node, _aliases), do: nil

  defp concat(parts), do: Enum.map_join(parts, ".", &to_string/1)
end
