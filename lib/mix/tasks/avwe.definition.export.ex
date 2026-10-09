defmodule Mix.Tasks.Avwe.Definition.Export do
  @shortdoc "Compiles a world definition from Quire and a recipe"

  @moduledoc """
  Writes a world's definition from its Quire folder and its recipe:

      mix avwe.definition.export ember-reach

  reads `priv/worlds/ember-reach/source.exs` (AVWE's own settings for the
  world, see `Avwe.Definition.Export`) and the Quire folder it names (under
  `config :avwe, :quire_root`), and writes `priv/worlds/ember-reach/definition.json`.

  Options:

    * `--quire DIR` - the Quire folder, instead of the recipe's `:quire`
    * `--source FILE` - the recipe, instead of `priv/worlds/NAME/source.exs`
    * `--out FILE` - where to write, instead of `priv/worlds/NAME/definition.json`

  The file written is read back and must give the definition that was made,
  with the same hash; the task stops otherwise.
  """

  use Mix.Task

  alias Avwe.{Definition, Definitions}
  alias Avwe.Definition.Export

  @switches [quire: :string, source: :string, out: :string]

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: @switches)

    name =
      case names do
        [name] ->
          name

        _other ->
          Mix.raise(
            "usage: mix avwe.definition.export NAME [--quire DIR] [--source FILE] [--out FILE]"
          )
      end

    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:yaml_elixir)

    source = Keyword.get(opts, :source, Path.join(["priv", "worlds", name, "source.exs"]))
    out = Keyword.get(opts, :out, Path.join(["priv", "worlds", name, "definition.json"]))
    recipe = recipe!(source)

    definition = definition!(quire_dir!(recipe, opts), recipe)
    write!(out, definition)
  end

  # The recipe is the operator's own file, evaluated as a script is.
  # sobelow_skip ["RCE.CodeModule"]
  defp recipe!(path) do
    if not File.exists?(path), do: Mix.raise("no recipe at #{path}")

    case Code.eval_file(path) do
      {recipe, _bindings} when is_list(recipe) -> recipe
      {other, _bindings} -> Mix.raise("#{path} must give a keyword list, got #{inspect(other)}")
    end
  end

  # A folder given on the command line is relative to where it was typed; the
  # recipe's is a world's name in Quire's own folder.
  defp quire_dir!(recipe, opts) do
    case {Keyword.get(opts, :quire), recipe[:quire]} do
      {nil, nil} -> Mix.raise("no Quire folder: give --quire DIR, or :quire in the recipe")
      {nil, name} -> Path.expand(name, Application.get_env(:avwe, :quire_root, "."))
      {dir, _name} -> Path.expand(dir)
    end
  end

  defp definition!(quire_dir, recipe) do
    case Avwe.Quire.load(quire_dir) do
      {:ok, world} -> from_quire!(world, recipe)
      {:error, reason} -> Mix.raise("cannot read Quire world #{quire_dir}: #{inspect(reason)}")
    end
  end

  defp from_quire!(world, recipe) do
    Export.from_quire(world, recipe)
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write!(out, definition) do
    File.mkdir_p!(Path.dirname(out))
    File.write!(out, Definition.to_json(definition))

    case Definitions.load(out) do
      {:ok, ^definition} ->
        Mix.shell().info(
          "Wrote #{out}: #{length(definition.entities)} entities, hash #{Definition.hash(definition)}"
        )

      {:ok, _other} ->
        Mix.raise("#{out} does not read back as the definition that was made")

      {:error, reason} ->
        Mix.raise(Definition.explain(reason))
    end
  end
end
