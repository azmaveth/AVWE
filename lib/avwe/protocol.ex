defmodule Avwe.Protocol do
  @moduledoc """
  The wire form of what a body perceives: percepts and looks as plain data
  that any adapter can send as JSON (`docs/DESIGN.md`, 8.2; `docs/m3-spec.md`,
  3). The MCP server's `structuredContent` is this form now, and a Channels
  adapter would send it. Pure.

  A **percept** is a map with these keys, a key being left out when it has no
  value:

    * `id` - the session's own number for it, such as `"p-12"`.
    * `kind` - `sensed` (noticed without asking), `progress` (an action of the
      body's own is under way) or `result` (an intent has finished).
    * `type` - the world event it came from (`speech`, `arrived`,
      `action_result`, ...).
    * `time` - when, as a world time relative to now (`"05:19"`, with the day
      when it was not today).
    * `summary` - plain prose every client can show as it is.
    * `modality` (`hearing`, `sight`, `smell`), `salience` and `confidence`,
      from 0 to 1.
    * `source` - where a sensed percept came from: `ref`, `distance_m`,
      `direction`.
    * `ref` - the intent a `progress` or `result` is of; `outcome` (`success`,
      `failure`, `blocked`, `interrupted`), `reason` and `issuer`
      (`controller` or `autopilot`) with it.
    * `data` - what a percept says beyond its summary, as data.

  **Whose words are whose.** The `summary` is the world's narration, with
  other players' words quoted inside it for people to read. What a client that
  must tell the two apart reads is in `data`: `data.words` on speech (`text`,
  `volume`, `speaker`, and `as`, how the listener names the speaker: a name,
  which is a player's text too, or `"Someone"`), on what a body heard and on
  what it said itself (`as` is then `"You"`, and `data.heard_by` lists the
  bodies in earshot it could see, `{ref, name}`, with `data.unseen` the
  number it could not); and `data.pages` (`time`, `text`, `by`, the kind of
  controller that wrote it, when there was one) on what a body read in its
  notebook. Every character another player chose is in a `summary`, in
  `words` or `pages`, or in a name (a `heard_by` name, `as`, a body's name in a
  look); no other field is a player's text.
  """

  alias Avwe.{Calendar, Percept, Prose}

  @doc "A percept as JSON-ready data, with `now` the world time its `time` is told against."
  @spec percept(Percept.t(), integer()) :: map()
  def percept(%Percept{} = percept, now) do
    percept
    |> Map.take([
      :id,
      :kind,
      :type,
      :summary,
      :modality,
      :outcome,
      :reason,
      :issuer,
      :salience,
      :confidence,
      :source,
      :data
    ])
    |> Map.put(:time, Prose.stamp(percept.time, now))
    |> Map.put(:ref, percept.intent)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> jsonable()
  end

  @doc """
  A look as JSON-ready data: its time formatted (and a wait's end), and
  its measures rounded, temperatures (`*_c`) to 0.1 degree and the rest to
  two places.
  """
  @spec look(map()) :: map()
  def look(look) do
    look
    |> Map.drop([:away])
    |> Map.put(:time, Calendar.format(look.time))
    |> Map.update(:action, nil, &look_action/1)
    |> rounded()
    |> jsonable()
  end

  defp look_action(%{until: until} = action) when is_integer(until),
    do: %{action | until: Calendar.format(until)}

  defp look_action(action), do: action

  defp rounded(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, rounded(key, value)} end)

  defp rounded(list) when is_list(list), do: Enum.map(list, &rounded/1)
  defp rounded(other), do: other

  defp rounded(key, value) when is_float(value) do
    if key |> to_string() |> String.ends_with?("_c"),
      do: Float.round(value, 1),
      else: Float.round(value, 2)
  end

  defp rounded(_key, value), do: rounded(value)

  @doc "Makes a term encodable as JSON: structs become maps and tuples become lists."
  @spec jsonable(term()) :: term()
  def jsonable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> jsonable()
  def jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, jsonable(v)} end)
  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(other), do: other
end
