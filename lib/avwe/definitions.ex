defmodule Avwe.Definitions do
  @moduledoc """
  The world definitions on disk: `priv/worlds/<name>/definition.json`. Reads a
  file and hands its text to `Avwe.Definition`, which does the rest. Like
  `Avwe.Quire`, this does file I/O and so is not part of the simulation core.
  """

  alias Avwe.Definition

  @name ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @doc """
  Reads a definition from a file. `name_or_path` is a name such as
  `"ember-reach"`, read from `<root>/<name>/definition.json` (the root is
  `config :avwe, :definitions_root`, default `priv/worlds`), or a path ending
  in `.json`.

  Fails with `{:invalid_definition, path, problems}` and every problem in the
  file, `{:read_definition, path, reason}` when it cannot be read, or
  `{:bad_definition_name, name}`.
  """
  @spec load(String.t()) :: {:ok, Definition.t()} | {:error, Definition.reason()}
  def load(name_or_path) do
    with {:ok, path} <- locate(name_or_path),
         {:ok, text} <- read(path) do
      case Definition.from_json(text) do
        {:ok, definition} -> {:ok, definition}
        {:error, problems} -> {:error, {:invalid_definition, path, problems}}
      end
    end
  end

  # A name is a folder of the definitions root; a path is taken as it is. Both
  # come from the operator's configuration, never from a controller.
  defp locate(name) when is_binary(name) do
    cond do
      String.ends_with?(name, ".json") -> {:ok, Path.expand(name)}
      Regex.match?(@name, name) -> {:ok, Path.join([root(), name, "definition.json"])}
      true -> {:error, {:bad_definition_name, name}}
    end
  end

  defp root, do: Application.get_env(:avwe, :definitions_root) || default_root()
  defp default_root, do: Application.app_dir(:avwe, Path.join("priv", "worlds"))

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:read_definition, path, reason}}
    end
  end
end
