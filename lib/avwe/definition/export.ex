defmodule Avwe.Definition.Export do
  @moduledoc """
  Compiles a world definition from a Quire world and AVWE's own settings for
  it (the **recipe**: `:seed`, `:start`, `:dt`, `:terrain`, `:hearths`,
  `:miracles`, `:climate`, `:characters` and `:guests`, as `Avwe.Worldgen`
  describes them). Quire gives the places and bodies; the recipe gives the rest.
  Pure: `mix avwe.definition.export` reads the files.

  This is how the Ember Reach's `definition.json` is made today, from the
  Quire folder and `priv/worlds/ember-reach/source.exs`. Once a language model
  compiles a world from Quire (`docs/quire-spec.md`), its output has the same
  shape, and this stays as the check that the loader reads what Quire and the
  recipe built, region for region (`test/avwe/definition/equality_test.exs`).

  The result is **normalised**: written as the schema writes it and read back,
  so the definition returned is the one a file of it would give, and a recipe
  the schema cannot hold is refused here with every problem, not later.
  """

  alias Avwe.{Definition, Worldgen}
  alias Avwe.Quire.{Article, Seed, World}

  @doc """
  The definition for `world` under `recipe`. Raises `ArgumentError`, with
  every problem, when the result is not a valid definition.
  """
  @spec from_quire(World.t(), keyword()) :: Definition.t()
  def from_quire(%World{} = world, recipe) do
    %Definition{
      id: world.id,
      name: world.name,
      tagline: world.tagline,
      description: world.description,
      seed: Keyword.fetch!(recipe, :seed),
      start: Keyword.get(recipe, :start, 0),
      dt: Keyword.get(recipe, :dt, 60),
      entities: entities(world),
      settings: settings(world, recipe),
      guests: recipe[:guests]
    }
    |> normalise()
  end

  # The entities `Avwe.Quire.Seed` builds, by id, each with its components.
  defp entities(world) do
    region = Seed.region(world, id: {0, 0}, seed: 0, grid: Worldgen.grid())

    region.components
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn id ->
      {id,
       for(
         {name, by_id} <- region.components,
         is_map_key(by_id, id),
         into: %{},
         do: {name, by_id[id]}
       )}
    end)
  end

  defp settings(world, recipe) do
    [
      terrain: recipe[:terrain],
      hearths: recipe[:hearths],
      miracles: recipe[:miracles] && Enum.map(recipe[:miracles], &miracle(&1, world)),
      climate: recipe[:climate],
      characters: recipe[:characters]
    ]
    |> Enum.reject(fn {_key, value} -> value == nil end)
  end

  # A standing miracle is named and described by the Quire article with its
  # id when there is one (as `Avwe.Worldgen` did), else by the recipe, else by
  # its id; the definition carries the words, since it has no Quire to ask.
  defp miracle(miracle, world) do
    if miracle[:kind] == :standing,
      do: named(miracle, world.articles[miracle[:id]]),
      else: miracle
  end

  defp named(miracle, %Article{title: title, summary: summary}),
    do: miracle |> Keyword.put(:name, title) |> Keyword.put(:description, summary)

  defp named(miracle, nil), do: Keyword.put_new(miracle, :name, miracle[:id])

  defp normalise(definition) do
    case definition |> Definition.encode() |> Definition.decode() do
      {:ok, normalised} ->
        normalised

      {:error, problems} ->
        raise ArgumentError,
              "the recipe does not make a valid definition:\n" <>
                Enum.map_join(problems, "\n", &("  " <> &1))
    end
  end
end
