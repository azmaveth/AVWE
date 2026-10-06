defmodule Avwe.Quire.World do
  @moduledoc """
  A Quire world as loaded from disk: metadata, articles, map pins and the canon
  timeline.
  """

  alias Avwe.Quire.Article

  defmodule Pin do
    @moduledoc "A map pin. `x` and `y` are percentages of the map sketch."
    @enforce_keys [:id, :label, :x, :y]
    defstruct [:id, :label, :x, :y, :article_id]

    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            x: number(),
            y: number(),
            article_id: String.t() | nil
          }
  end

  defmodule TimelineEvent do
    @moduledoc "A canon event. `sort_key` orders events; `date_label` is for people."
    @enforce_keys [:id, :title, :sort_key]
    defstruct [:id, :title, :date_label, :sort_key, :summary, :article_id]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t(),
            date_label: String.t() | nil,
            sort_key: number(),
            summary: String.t() | nil,
            article_id: String.t() | nil
          }
  end

  @enforce_keys [:id, :name]
  defstruct [:id, :name, :tagline, :description, articles: %{}, pins: [], timeline: []]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          tagline: String.t() | nil,
          description: String.t() | nil,
          articles: %{String.t() => Article.t()},
          pins: [Pin.t()],
          timeline: [TimelineEvent.t()]
        }

  @doc "Builds a world from the decoded JSON files and parsed articles."
  @spec new(map(), map(), map(), [Article.t()]) :: t()
  def new(world, map, timeline, articles) do
    %__MODULE__{
      id: world["id"],
      name: world["name"],
      tagline: world["tagline"],
      description: world["description"],
      articles: Map.new(articles, &{&1.id, &1}),
      pins: Enum.map(map["pins"] || [], &pin/1),
      timeline:
        timeline["events"] |> List.wrap() |> Enum.map(&event/1) |> Enum.sort_by(& &1.sort_key)
    }
  end

  @doc "The article with this exact title, or `nil`."
  @spec article_by_title(t(), String.t()) :: Article.t() | nil
  def article_by_title(%__MODULE__{articles: articles}, title) do
    articles |> Map.values() |> Enum.find(&(&1.title == title))
  end

  @doc "The first pin that points at this article, or `nil`."
  @spec pin_for_article(t(), String.t()) :: Pin.t() | nil
  def pin_for_article(%__MODULE__{pins: pins}, article_id) do
    Enum.find(pins, &(&1.article_id == article_id))
  end

  defp pin(p) do
    %Pin{id: p["id"], label: p["label"], x: p["x"], y: p["y"], article_id: p["articleId"]}
  end

  defp event(e) do
    %TimelineEvent{
      id: e["id"],
      title: e["title"],
      date_label: e["dateLabel"],
      sort_key: e["sortKey"],
      summary: e["summary"],
      article_id: e["articleId"]
    }
  end
end
