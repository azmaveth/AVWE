defmodule Avwe.Guests do
  @moduledoc """
  Guests: bodies that are not canon, made when a controller arrives with a
  name and a backstory of its own (`docs/m3-spec.md`, 2). Pure.

  A guest arrives by an `:arrive` intent (`Avwe.Actions`), which the
  simulation applies like any other and the journal replays: the intent
  carries the guest's cleaned `name` and `backstory`, the `arrival` place and
  the most guests the world takes (`max`), which the world is started with
  (`Avwe.start_world/2`, `:guests`), so a replay under another configuration
  gives the same world. `check/2` is the one rule for whether it is allowed:
  `Avwe.RegionServer` asks it before the intent is journaled, counting the
  arrivals still waiting for the next step, and the step asks it again.

  What a controller offers is made one line of plain text (`Avwe.Text`), and
  a name is 2 to 40 characters of letters, digits, spaces, hyphens,
  apostrophes and full stops, two of them at least letters, which is not one
  of the words the world uses for people it cannot name. It is refused as
  taken when, ignoring case, accents, spaces and punctuation, it is the name
  or the id of anything in the world: nobody poses as Mira Vale, and nobody
  is named after a place. The body's id is `guest-` and the name's words in
  lower-case ASCII joined with hyphens (a name with none gets a hash of
  itself). A backstory is optional and up to 1 000 characters.

  The guest is made at the arrival place, knowing the pinned places and not
  the places that are not (the river's source is for someone to find), with a
  pocket notebook of its own, its memory across sessions. It has no routine:
  autopilot rests it at night and otherwise lets it wait. Its `repr` says only
  that it is a guest; its backstory is its controller's, in a `guest`
  component that `Avwe.bodies/1` marks and the MCP server tells whoever plays
  it.
  """

  alias Avwe.{Autopilot, Event, Intent, Region, Text, Tick}

  @prefix "guest-"
  @name_length 2..40
  @max_backstory 1_000
  @reserved ~w(you someone anyone nobody everyone stranger)
  @description "A guest."

  @type reason ::
          :invalid_name
          | :invalid_backstory
          | :name_taken
          | :full
          | :no_guests
          | :no_arrival_place

  @type offer :: %{id: String.t(), name: String.t(), backstory: String.t() | nil}

  @doc """
  What a controller offers, cleaned and checked on its own: the guest's name
  and backstory as they will be kept, and the id its body will have. Whether
  the world has room, or the name is free, is `check/2`'s.
  """
  @spec offer(term(), term()) :: {:ok, offer()} | {:error, :invalid_name | :invalid_backstory}
  def offer(name, backstory) do
    with {:ok, name} <- name(name),
         {:ok, backstory} <- backstory(backstory) do
      {:ok, %{id: id(name), name: name, backstory: backstory}}
    end
  end

  @doc """
  Whether the region would take this `:arrive` intent: the offer is sound
  and the body is its id, the arrival place is one, nothing in the world
  has the name or the id, and there is room. The arrivals waiting in the
  region's inbox count, as the guests already there do.
  """
  @spec check(Region.t(), Intent.t()) :: :ok | {:error, reason()}
  def check(%Region{} = region, %Intent{verb: :arrive, body: body, params: params}) do
    pending = pending(region)

    with {:ok, %{id: ^body} = offer} <- offered(params),
         {:ok, _place} <- arrival(region, params),
         :ok <- free(region, offer, pending),
         :ok <- room(region, params, pending) do
      :ok
    else
      {:ok, _other_id} -> {:error, :invalid_name}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Makes the guest of an `:arrive` intent as the step begins, or says why not:
  `{:ok, region, event}` with the `:arrived` event that others in sight are
  told of, or `{:error, reason}` as `check/2` does.
  """
  @spec arrive(Region.t(), Intent.t(), Tick.t()) ::
          {:ok, Region.t(), Event.t()} | {:error, reason()}
  def arrive(%Region{} = region, %Intent{} = intent, %Tick{} = tick) do
    with :ok <- check(region, intent),
         {:ok, %{id: id, name: name, backstory: backstory}} <- offered(intent.params),
         {:ok, {place, position}} <- arrival(region, intent.params) do
      region =
        region
        |> Region.put_entity(id, %{
          body: %{species: nil},
          repr: %{name: name, description: @description},
          guest: %{backstory: backstory, arrived_at: Tick.end_time(tick)},
          position: position,
          knows: MapSet.new(pinned(region)),
          autopilot: Autopilot.fresh(),
          control: %{holder: nil, since: nil}
        })
        |> Region.put_entity(notebook(id), %{
          item: %{kind: :notebook},
          carried_by: id,
          repr: %{name: "pocket notebook", description: "A guest's notebook."},
          notebook: %{pages: []}
        })

      {:ok, region, Event.new(:arrived, entity: id, data: %{place: place, position: position})}
    end
  end

  @doc "The id of the pocket notebook a guest's body carries."
  @spec notebook(String.t()) :: String.t()
  def notebook(id), do: id <> "-notebook"

  # What a controller offered

  defp offered(%{name: name} = params), do: offer(name, Map.get(params, :backstory))
  defp offered(_params), do: {:error, :invalid_name}

  defp name(name) when is_binary(name) do
    name = name |> Text.line() |> String.replace(~r/ +/, " ")

    cond do
      String.length(name) not in @name_length -> {:error, :invalid_name}
      not String.match?(name, ~r/\A[\p{L}\p{M}\p{N} '’.\-]+\z/u) -> {:error, :invalid_name}
      length(Regex.scan(~r/\p{L}/u, name)) < 2 -> {:error, :invalid_name}
      key(name) in @reserved -> {:error, :invalid_name}
      true -> {:ok, name}
    end
  end

  defp name(_other), do: {:error, :invalid_name}

  defp backstory(nil), do: {:ok, nil}

  defp backstory(text) when is_binary(text) do
    case Text.line(text) do
      "" -> {:ok, nil}
      line -> limit(line)
    end
  end

  defp backstory(_other), do: {:error, :invalid_backstory}

  defp limit(line) do
    if String.length(line) <= @max_backstory, do: {:ok, line}, else: {:error, :invalid_backstory}
  end

  # What two names are compared by: the letters and digits of the name, in
  # lower case, without accents.
  defp key(text) do
    text
    |> unaccent()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]/u, "")
  end

  defp id(name) do
    words =
      name
      |> unaccent()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    @prefix <> if(words == "", do: Integer.to_string(:erlang.phash2(name)), else: words)
  end

  defp unaccent(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{M}/u, "")
  end

  # The world

  defp arrival(region, %{arrival: place}) when is_binary(place) do
    position = Region.get(region, place, :position)

    if Region.get(region, place, :place) != nil and position != nil,
      do: {:ok, {place, position}},
      else: {:error, :no_arrival_place}
  end

  defp arrival(_region, _params), do: {:error, :no_guests}

  defp room(region, %{max: max}, pending) when is_integer(max) and max > 0 do
    there = region.components |> Map.get(:guest, %{}) |> map_size()
    if there + length(pending) < max, do: :ok, else: {:error, :full}
  end

  defp room(_region, _params, _pending), do: {:error, :no_guests}

  # The arrivals waiting for the next step.
  defp pending(%Region{inbox: inbox}),
    do: for(%Intent{verb: :arrive} = intent <- inbox, do: intent)

  # Nothing in the world is called what the guest would be, by name or by id,
  # nor has the id of its body or its notebook.
  defp free(region, %{id: id, name: name}, pending) do
    key = key(name)

    names =
      for {_id, %{name: other}} <- Map.get(region.components, :repr, %{}),
          is_binary(other),
          do: key(other)

    ids = region.components |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.map(&key/1)
    waiting = for %Intent{body: body} <- pending, do: body

    taken? =
      key in names or key in ids or id in waiting or
        Region.entity(region, id) != %{} or Region.entity(region, notebook(id)) != %{}

    if taken?, do: {:error, :name_taken}, else: :ok
  end

  # The places the world pins on its map, which anyone in the valley knows the
  # way to: those with an article (a pin's `:article`, which may be nothing).
  defp pinned(region), do: Region.with_components(region, [:place, :article])
end
