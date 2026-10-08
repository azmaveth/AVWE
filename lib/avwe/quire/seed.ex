defmodule Avwe.Quire.Seed do
  @moduledoc """
  Builds the starting state of a region from a Quire world. Pure.

  So far this creates:

    * a **place** for every map pin, at the pin's cell on the grid
    * a **body** for every character article, at its home if the home
      resolves to a pinned place. Characters know the way to every pinned
      place (`:knows`); places that aren't pinned, such as the river's
      source, have to be discovered.

  Every entity gets a `:repr` component with its name and description (the
  article summary) and an `:article` component linking back to canon. Terrain,
  the river and its source come next.

  Entity ids are Quire ids: pin ids for places, article ids for characters.

  A character is placed at its `home` only when that is a pinned place. One
  whose home is an article without a pin, or names nothing, or is missing, still
  gets a body, but a body that is **nowhere**: it has no `:position` (and no
  `:home`), so nobody can play it (`Avwe.elsewhere/1`), nobody sees it, and
  autopilot leaves it alone. `unplaced/1` names them, and the world says so when
  it starts.
  """

  alias Avwe.Quire.{Article, World}
  alias Avwe.Region

  @grid 256

  @doc """
  Builds a region. Takes the same options as `Avwe.Region.new/1`, plus `:grid`
  (cells per side of the map sketch, default #{@grid}).
  """
  @spec region(World.t(), keyword()) :: Region.t()
  def region(%World{} = world, opts) do
    grid = Keyword.get(opts, :grid, @grid)

    opts
    |> Keyword.delete(:grid)
    |> Region.new()
    |> add_places(world, grid)
    |> add_characters(world, grid)
  end

  @doc """
  The characters `region/2` cannot place, sorted by id: each with its `id`, its
  `name` and the `home` its article gives (`nil` when it gives none). They are
  the characters whose home is not a pinned place.
  """
  @spec unplaced(World.t()) :: [%{id: String.t(), name: String.t(), home: String.t() | nil}]
  def unplaced(%World{} = world) do
    world.articles
    |> Map.values()
    |> Enum.filter(&(&1.type == :character and home_pin(&1, world) == nil))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{id: &1.id, name: &1.title, home: home_title(&1)})
  end

  defp home_title(article) do
    case article.fields["home"] do
      title when is_binary(title) -> title
      _none -> nil
    end
  end

  defp add_places(region, world, grid) do
    Enum.reduce(world.pins, region, fn pin, acc ->
      article = pin.article_id && world.articles[pin.article_id]

      Region.put_entity(acc, pin.id, %{
        place: %{label: pin.label},
        position: cell(pin, grid),
        repr: %{name: pin.label, description: article && article.summary},
        article: pin.article_id
      })
    end)
  end

  defp add_characters(region, world, grid) do
    knows = MapSet.new(world.pins, & &1.id)

    world.articles
    |> Map.values()
    |> Enum.filter(&(&1.type == :character))
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce(region, &Region.put_entity(&2, &1.id, character(&1, world, grid, knows)))
  end

  defp character(%Article{} = article, world, grid, knows) do
    components = %{
      body: %{species: species(article, world)},
      repr: %{name: article.title, description: article.summary},
      article: article.id,
      knows: knows
    }

    case home_pin(article, world) do
      nil -> components
      home -> Map.merge(components, %{home: home.id, position: cell(home, grid)})
    end
  end

  defp home_pin(article, world) do
    with title when is_binary(title) <- article.fields["home"],
         %Article{id: id} <- World.article_by_title(world, title) do
      World.pin_for_article(world, id)
    else
      _no_home -> nil
    end
  end

  defp species(article, world) do
    case article.fields["species"] do
      nil -> nil
      title -> resolve_title(world, title)
    end
  end

  defp resolve_title(world, title) do
    case World.article_by_title(world, title) do
      %Article{id: id} -> id
      nil -> title
    end
  end

  defp cell(pin, grid), do: {to_cell(pin.x, grid), to_cell(pin.y, grid)}

  defp to_cell(percent, grid), do: (percent * grid / 100) |> trunc() |> min(grid - 1) |> max(0)
end
