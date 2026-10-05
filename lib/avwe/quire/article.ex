defmodule Avwe.Quire.Article do
  @moduledoc """
  One Quire article: front matter plus a markdown body.

  `type` is one of Quire's article templates as an atom. Unknown types become
  `:article`, Quire's generic template. `fields` keeps Quire's string keys,
  since they are authored and open-ended.
  """

  @types %{
    "character" => :character,
    "location" => :location,
    "organization" => :organization,
    "species" => :species,
    "item" => :item,
    "religion" => :religion,
    "event" => :event,
    "article" => :article
  }

  @enforce_keys [:id, :title, :type]
  defstruct [:id, :title, :type, :summary, fields: %{}, body: ""]

  @type type ::
          :character
          | :location
          | :organization
          | :species
          | :item
          | :religion
          | :event
          | :article

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          type: type(),
          summary: String.t() | nil,
          fields: %{String.t() => term()},
          body: String.t()
        }

  @doc "Builds an article from parsed front matter (string keys) and a body."
  @spec new(map(), String.t()) :: {:ok, t()} | {:error, {:missing, String.t()}}
  def new(attrs, body) do
    case Enum.find(["id", "title"], &blank?(attrs[&1])) do
      nil ->
        {:ok,
         %__MODULE__{
           id: attrs["id"],
           title: attrs["title"],
           type: Map.get(@types, attrs["type"], :article),
           summary: attrs["summary"],
           fields: attrs["fields"] || %{},
           body: body
         }}

      missing ->
        {:error, {:missing, missing}}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
