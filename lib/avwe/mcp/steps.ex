defmodule Avwe.MCP.Steps do
  @moduledoc """
  Turns the arguments of the MCP `act` tool into steps for `Avwe.Mind.act/3`.
  Pure.

  A step is `%{"verb" => verb, "target" => target, "params" => params}` as
  JSON gives it. Verbs are a fixed list. A target of `go`, `kindle`,
  `douse`, `write` or `read` is a name, passed on as `:target_name`: the
  Mind resolves it when it submits that step, against what the body knows
  and reaches then (`Avwe.Mind`), so a plan can name a hearth at the end of
  a journey; a name that matches nothing is passed on as given, for the
  world to refuse in its own words.

  Everything that can be checked without the world is checked here, before
  anything is submitted, and refused in plain words: a plan has at most
  50 steps; `say` and `write` need their text; a volume, a moment to
  wait until and a direction to follow come from fixed lists (and only
  those become atoms); a wait takes exactly one of `minutes`, `hours`,
  `for` (seconds) and `until`, and lasts from a minute to a week; `read`
  takes from 1 to 50 pages. The world still has the last word on the rest.
  """

  @verbs ~w(go follow walk wait say stop kindle douse write read)
  @max_steps 50
  @max_speech 500
  @max_page 1_000
  @max_read 50
  @min_wait 60
  @max_wait 7 * 86_400
  @volumes %{"whisper" => :whisper, "talk" => :talk, "say" => :talk, "shout" => :shout}
  @moments %{"dawn" => :dawn, "sunrise" => :dawn, "dusk" => :dusk, "sunset" => :dusk}
  @flows %{
    "upstream" => :upstream,
    "up" => :upstream,
    "downstream" => :downstream,
    "down" => :downstream
  }
  @wait_units [{"minutes", 60}, {"hours", 3_600}, {"for", 1}, {"until", nil}]
  @compass %{
    "n" => "north",
    "north" => "north",
    "ne" => "north-east",
    "northeast" => "north-east",
    "e" => "east",
    "east" => "east",
    "se" => "south-east",
    "southeast" => "south-east",
    "s" => "south",
    "south" => "south",
    "sw" => "south-west",
    "southwest" => "south-west",
    "w" => "west",
    "west" => "west",
    "nw" => "north-west",
    "northwest" => "north-west"
  }

  @doc "The verbs the MCP server takes."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc "The most steps a plan may have."
  @spec max_steps() :: pos_integer()
  def max_steps, do: @max_steps

  @doc """
  The steps that `args` ask for: from `"steps"` (a list of step objects)
  or from `"verb"`, `"target"` and `"params"` (one step), not both. Fails
  with a message for the player.
  """
  @spec parse(map()) :: {:ok, [{atom(), keyword()}]} | {:error, String.t()}
  def parse(%{"steps" => steps, "verb" => verb}) when steps != nil and verb != nil,
    do: {:error, "Give either a verb or a list of steps, not both."}

  def parse(%{"steps" => []}), do: {:error, "The list of steps is empty."}

  def parse(%{"steps" => steps}) when is_list(steps) and length(steps) > @max_steps,
    do:
      {:error,
       "A plan has at most #{@max_steps} steps; this one has #{length(steps)}. " <>
         "Plan the first part, and the rest when it is done."}

  def parse(%{"steps" => steps}) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, n}, {:ok, acc} ->
      case step(step) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, message} -> {:halt, {:error, "Step #{n}: #{message}"}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  def parse(%{"steps" => steps}) when steps != nil,
    do: {:error, "steps must be a list of objects like {\"verb\": \"go\", \"target\": \"...\"}."}

  def parse(%{"verb" => verb} = args) when verb != nil do
    with {:ok, step} <- step(args), do: {:ok, [step]}
  end

  def parse(_args), do: {:error, "Give a verb (or a list of steps)."}

  defp step(%{"verb" => verb} = step) when is_binary(verb) do
    with {:ok, verb} <- verb(verb),
         {:ok, params} <- params(verb, Map.get(step, "params") || %{}, Map.get(step, "target")),
         {:ok, name} <- target(verb, Map.get(step, "target")) do
      opts = if name, do: [target_name: name, params: params], else: [params: params]
      {:ok, {verb, opts}}
    end
  end

  defp step(%{"verb" => verb}),
    do: {:error, "The verb must be a string, not #{inspect(verb)}."}

  defp step(_step), do: {:error, "Each step needs a verb."}

  defp verb(verb) do
    verb = verb |> String.trim() |> String.downcase()

    if verb in @verbs,
      do: {:ok, String.to_existing_atom(verb)},
      else: {:error, "Unknown verb \"#{verb}\". The verbs are: #{Enum.join(@verbs, ", ")}."}
  end

  # Targets: names, which the Mind resolves when it submits the step.

  defp target(:go, nil), do: {:error, "go needs a target: a place."}
  defp target(:go, query), do: name(query, "place")
  defp target(verb, nil) when verb in [:kindle, :douse, :write, :read], do: {:ok, nil}
  defp target(verb, query) when verb in [:kindle, :douse], do: name(query, "hearth")
  defp target(verb, query) when verb in [:write, :read], do: name(query, "notebook")
  defp target(_verb, _query), do: {:ok, nil}

  defp name(query, _kind) when is_binary(query), do: {:ok, query}
  defp name(_query, kind), do: {:error, "The #{kind} must be named with a string."}

  # Parameters

  defp params(_verb, params, _target) when not is_map(params),
    do: {:error, "params must be an object."}

  defp params(:say, params, _target) do
    with {:ok, text} <- text(params["text"], "say", "what to say", @max_speech),
         {:ok, volume} <-
           choice(params["volume"] || "talk", @volumes, "volume", "whisper, talk or shout") do
      {:ok, %{text: text, volume: volume}}
    end
  end

  defp params(:write, params, _target) do
    with {:ok, text} <- text(params["text"], "write", "the page to write", @max_page),
         do: {:ok, %{text: text}}
  end

  defp params(:wait, params, _target) do
    case Enum.filter(@wait_units, fn {key, _unit} -> params[key] != nil end) do
      [{"until", nil}] ->
        with {:ok, moment} <- choice(params["until"], @moments, "until", "dawn or dusk"),
             do: {:ok, %{until: moment}}

      [{key, unit}] ->
        wait_for(params[key], key, unit)

      [] ->
        {:error, "wait needs one of: minutes, hours, for (seconds) or until (dawn or dusk)."}

      given ->
        names = Enum.map_join(given, " and ", &elem(&1, 0))
        {:error, "wait takes one of minutes, hours, for or until, not #{names} together."}
    end
  end

  defp params(:follow, params, target) do
    case params["direction"] || target do
      nil ->
        {:error, "follow needs a direction: upstream or downstream."}

      direction ->
        with {:ok, flow} <- choice(direction, @flows, "direction", "upstream or downstream"),
             do: {:ok, %{direction: flow}}
    end
  end

  defp params(:walk, params, _target) do
    direction = params["direction"]

    direction =
      if is_binary(direction),
        do:
          Map.get(
            @compass,
            direction |> String.downcase() |> String.replace(~r/[\s-]/, ""),
            direction
          ),
        else: direction

    distance = params["distance_m"] || params["meters"]
    {:ok, Map.reject(%{direction: direction, distance_m: distance}, fn {_k, v} -> is_nil(v) end)}
  end

  defp params(:read, params, _target) do
    case params["last"] do
      nil ->
        {:ok, %{}}

      last when is_integer(last) and last >= 1 and last <= @max_read ->
        {:ok, %{last: last}}

      _other ->
        {:error, "last must be a whole number of pages from 1 to #{@max_read}."}
    end
  end

  defp params(_verb, _params, _target), do: {:ok, %{}}

  defp text(text, verb, what, max) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:error, "#{verb} needs text: #{what}."}
      String.length(trimmed) > max -> {:error, "The text is too long: at most #{max} characters."}
      true -> {:ok, text}
    end
  end

  defp text(nil, verb, what, _max), do: {:error, "#{verb} needs text: #{what}."}
  defp text(_other, _verb, _what, _max), do: {:error, "The text must be a string."}

  defp choice(value, choices, field, listed) do
    found = if is_binary(value), do: Map.get(choices, value |> String.trim() |> String.downcase())

    if found,
      do: {:ok, found},
      else: {:error, "#{field} must be #{listed}, not #{inspect(value)}."}
  end

  defp wait_for(n, key, unit) when is_number(n) do
    seconds = round(n * unit)

    cond do
      seconds < @min_wait -> {:error, "A wait lasts at least a minute (#{key}: #{n})."}
      seconds > @max_wait -> {:error, "A wait lasts at most a week (#{key}: #{n})."}
      true -> {:ok, %{for: seconds}}
    end
  end

  defp wait_for(n, key, _unit), do: {:error, "#{key} must be a number, not #{inspect(n)}."}
end
