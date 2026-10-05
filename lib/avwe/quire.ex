defmodule Avwe.Quire do
  @moduledoc """
  Reads a world from a Quire world folder.

  Quire is canon, so this is read-only: AVWE never writes to these files. A
  world folder looks like:

      <world-id>/
        world.json       name, tagline, description
        map.json         pins
        timeline.json    canon events
        articles/*.md    YAML front matter plus a markdown body

  This module does file I/O and is not part of the simulation core.
  `Avwe.Quire.Seed` turns the loaded world into simulation state.
  """

  alias Avwe.Quire.{Article, World}

  @doc "Loads the world in `dir`."
  @spec load(Path.t()) :: {:ok, World.t()} | {:error, term()}
  def load(dir) do
    with {:ok, world} <- read_json(dir, "world.json"),
         {:ok, map} <- read_json(dir, "map.json"),
         {:ok, timeline} <- read_json(dir, "timeline.json"),
         {:ok, articles} <- read_articles(Path.join(dir, "articles")) do
      {:ok, World.new(world, map, timeline, articles)}
    end
  end

  defp read_json(dir, name) do
    path = Path.join(dir, name)

    with {:ok, text} <- read(path) do
      case JSON.decode(text) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, {:invalid_json, path, reason}}
      end
    end
  end

  defp read_articles(dir) do
    with {:ok, names} <- list(dir) do
      names
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.sort()
      |> Enum.map(&Path.join(dir, &1))
      |> read_each([])
    end
  end

  defp read_each([], acc), do: {:ok, Enum.reverse(acc)}

  defp read_each([path | rest], acc) do
    case read_article(path) do
      {:ok, article} -> read_each(rest, [article | acc])
      error -> error
    end
  end

  defp read_article(path) do
    with {:ok, text} <- read(path) do
      parse_article(path, text)
    end
  end

  @doc false
  @spec parse_article(Path.t(), String.t()) :: {:ok, Article.t()} | {:error, term()}
  def parse_article(path, text) do
    with ["", front, body] <- String.split(text, ~r/^---[ \t]*$/m, parts: 3),
         {:ok, attrs} when is_map(attrs) <- YamlElixir.read_from_string(front),
         {:ok, article} <- Article.new(attrs, String.trim(body)) do
      {:ok, article}
    else
      {:error, {:missing, field}} -> {:error, {:invalid_article, path, {:missing, field}}}
      _other -> {:error, {:invalid_article, path, :front_matter}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:read, path, reason}}
    end
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, {:read, dir, reason}}
    end
  end
end
