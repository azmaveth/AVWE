defmodule Avwe.MCP.Steps do
  @moduledoc """
  Turns the arguments of the MCP `act` tool into steps for `Avwe.Mind.act/3`.
  Pure.

  A step is `%{"verb" => verb, "target" => target, "params" => params}` as
  JSON gives it. Verbs are a fixed list; names are matched against the
  body's look (places it knows, hearths in reach, what it carries), as the
  telnet front door does, and a name that matches nothing is passed on as
  given, for the world to refuse in its own words. Parameter values that
  the world takes as atoms (volumes, moments, directions upstream and
  downstream) are only ever made from a fixed list; anything else is passed
  on as a string, and the world refuses it.
  """

  alias Avwe.Telnet.Command

  @verbs ~w(go follow walk wait say stop kindle douse write read)
  @volumes %{"whisper" => :whisper, "talk" => :talk, "say" => :talk, "shout" => :shout}
  @moments %{"dawn" => :dawn, "sunrise" => :dawn, "dusk" => :dusk, "sunset" => :dusk}
  @flows %{
    "upstream" => :upstream,
    "up" => :upstream,
    "downstream" => :downstream,
    "down" => :downstream
  }
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

  @doc """
  The steps that `args` ask for, against the body's `look`: from `"steps"`
  (a list of step objects) or from `"verb"`, `"target"` and `"params"` (one
  step), not both. Fails with a message for the player.
  """
  @spec parse(map(), map()) :: {:ok, [{atom(), keyword()}]} | {:error, String.t()}
  def parse(%{"steps" => steps, "verb" => verb}, _look) when steps != nil and verb != nil,
    do: {:error, "Give either a verb or a list of steps, not both."}

  def parse(%{"steps" => []}, _look), do: {:error, "The list of steps is empty."}

  def parse(%{"steps" => steps}, look) when is_list(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, n}, {:ok, acc} ->
      case step(step, look) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, message} -> {:halt, {:error, "Step #{n}: #{message}"}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  def parse(%{"steps" => steps}, _look) when steps != nil,
    do: {:error, "steps must be a list of objects like {\"verb\": \"go\", \"target\": \"...\"}."}

  def parse(%{"verb" => verb} = args, look) when verb != nil do
    with {:ok, step} <- step(args, look), do: {:ok, [step]}
  end

  def parse(_args, _look), do: {:error, "Give a verb (or a list of steps)."}

  defp step(%{"verb" => verb} = step, look) when is_binary(verb) do
    with {:ok, verb} <- verb(verb),
         {:ok, params} <- params(verb, Map.get(step, "params") || %{}, Map.get(step, "target")),
         {:ok, target} <- target(verb, Map.get(step, "target"), look) do
      opts = if target, do: [target: target, params: params], else: [params: params]
      {:ok, {verb, opts}}
    end
  end

  defp step(%{"verb" => verb}, _look),
    do: {:error, "The verb must be a string, not #{inspect(verb)}."}

  defp step(_step, _look), do: {:error, "Each step needs a verb."}

  defp verb(verb) do
    verb = verb |> String.trim() |> String.downcase()

    if verb in @verbs,
      do: {:ok, String.to_existing_atom(verb)},
      else: {:error, "Unknown verb \"#{verb}\". The verbs are: #{Enum.join(@verbs, ", ")}."}
  end

  # Targets

  defp target(verb, nil, _look) when verb in [:go], do: {:error, "go needs a target: a place."}
  defp target(:go, query, look), do: name(query, places(look), "place")

  defp target(verb, query, look) when verb in [:kindle, :douse] and is_binary(query),
    do: name(query, Enum.map(look[:hearths] || [], &{&1.id, &1.name}), "hearth")

  defp target(verb, query, look) when verb in [:write, :read] and is_binary(query),
    do: name(query, Enum.map(look[:carried] || [], &{&1.id, &1.name}), "notebook")

  defp target(_verb, _query, _look), do: {:ok, nil}

  defp places(look) do
    here = if look[:here], do: [{look.here.id, look.here.name}], else: []
    Enum.map(look[:places] || [], &{&1.id, &1.name}) ++ here
  end

  defp name(query, _candidates, kind) when not is_binary(query),
    do: {:error, "The #{kind} must be named with a string."}

  defp name(query, candidates, _kind) do
    case Command.resolve(query, candidates) do
      {:ok, id} -> {:ok, id}
      {:ambiguous, names} -> {:error, "Which do you mean: #{Enum.join(names, ", ")}?"}
      :none -> {:ok, query}
    end
  end

  # Parameters

  defp params(_verb, params, _target) when not is_map(params),
    do: {:error, "params must be an object."}

  defp params(:say, params, _target) do
    volume = params |> Map.get("volume", "talk") |> pick(@volumes)
    {:ok, %{text: Map.get(params, "text"), volume: volume}}
  end

  defp params(:wait, params, _target) do
    cond do
      until = params["until"] ->
        {:ok, %{until: pick(until, @moments)}}

      minutes = params["minutes"] ->
        {:ok, %{for: seconds(minutes, 60)}}

      hours = params["hours"] ->
        {:ok, %{for: seconds(hours, 3_600)}}

      for = params["for"] ->
        {:ok, %{for: seconds(for, 1)}}

      true ->
        {:error, "wait needs params: minutes, hours, for (seconds) or until (dawn or dusk)."}
    end
  end

  defp params(:follow, params, target) do
    {:ok, %{direction: pick(params["direction"] || target, @flows)}}
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

  defp params(:write, params, _target), do: {:ok, %{text: params["text"]}}

  defp params(:read, params, _target) do
    case params["last"] do
      nil -> {:ok, %{}}
      last -> {:ok, %{last: last}}
    end
  end

  defp params(_verb, _params, _target), do: {:ok, %{}}

  defp pick(value, choices) when is_binary(value),
    do: Map.get(choices, value |> String.trim() |> String.downcase(), value)

  defp pick(value, _choices), do: value

  defp seconds(n, unit) when is_number(n), do: round(n * unit)
  defp seconds(other, _unit), do: other
end
