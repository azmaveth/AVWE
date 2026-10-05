defmodule Avwe.Actions do
  @moduledoc """
  What happens when a controller asks a body to do something. Pure.

  Every intent ends in exactly one `:action_result` event carrying its ref,
  with an outcome from Arbor's vocabulary: `:success`, `:failure`, `:blocked`
  or `:interrupted`.

  Instant actions (speaking, stopping) finish in the step they start. Durative
  actions (going, following, walking, waiting) live in the body's `:action`
  component until a system completes them, `:stop` interrupts them, or a new
  action replaces them. Journeys carry a `:path` of waypoints that
  `Avwe.Systems.Movement` walks along.
  """

  alias Avwe.{Calendar, Event, Intent, Region, Space, Terrain, Tick}
  alias Avwe.Systems.Daylight

  @volumes [:whisper, :talk, :shout]
  @max_speech 500
  @max_wait 7 * 86_400
  @moments %{dawn: :sunrise, sunrise: :sunrise, dusk: :sunset, sunset: :sunset}
  @default_map_cells 256
  @walk_m 10..2_000

  @doc "Applies an intent at the start of a step."
  @spec handle(Region.t(), Intent.t(), Tick.t()) :: {Region.t(), [Event.t()]}
  def handle(region, %Intent{} = intent, tick) do
    if Region.get(region, intent.body, :body) do
      perform(region, intent, tick)
    else
      {region, [result(intent, :blocked, :no_such_body)]}
    end
  end

  @doc "Ends a body's current action with an outcome and removes it."
  @spec complete(Region.t(), Region.entity_id(), atom(), atom() | nil) ::
          {Region.t(), [Event.t()]}
  def complete(region, body, outcome, reason) do
    case Region.get(region, body, :action) do
      nil ->
        {region, []}

      action ->
        {Region.delete_component(region, body, :action),
         [finished(body, action, outcome, reason)]}
    end
  end

  defp perform(region, %Intent{verb: :go} = intent, _tick) do
    here = Region.get(region, intent.body, :position)

    case known_place(region, intent.body, intent.target) do
      nil ->
        {region, [result(intent, :blocked, :unknown_place)]}

      ^here ->
        {region, [result(intent, :success, :already_there)]}

      destination ->
        travel(region, intent, [here, destination], %{toward: intent.target})
    end
  end

  defp perform(region, %Intent{verb: :follow} = intent, _tick) do
    here = Region.get(region, intent.body, :position)

    with {:ok, direction} <- follow_direction(intent.params),
         {:ok, path} <- channel_route(region.terrain, here, direction) do
      intent = %{intent | params: %{direction: direction}}

      case path do
        [_here] -> {region, [result(intent, :success, :end_of_channel)]}
        path -> travel(region, intent, path, %{heading: Atom.to_string(direction)})
      end
    else
      {:error, reason} -> {region, [result(intent, :blocked, reason)]}
    end
  end

  defp perform(region, %Intent{verb: :walk} = intent, _tick) do
    here = Region.get(region, intent.body, :position)

    case walk_params(intent.params) do
      {:ok, direction, meters} ->
        intent = %{intent | params: %{direction: direction, distance_m: meters}}
        target = Space.offset(here, direction, meters / Space.cell_size_m(), map_cells(region))

        if target == here,
          do: {region, [result(intent, :blocked, :edge)]},
          else: travel(region, intent, [here, target], %{heading: direction})

      :error ->
        {region, [result(intent, :blocked, :invalid)]}
    end
  end

  defp perform(region, %Intent{verb: :wait} = intent, tick) do
    case wait_until(intent.params, tick.time) do
      {:ok, until} -> start(region, intent.body, Map.put(action_base(intent), :until, until), [])
      :error -> {region, [result(intent, :blocked, :invalid)]}
    end
  end

  defp perform(region, %Intent{verb: :say, params: params} = intent, _tick) do
    text = params |> Map.get(:text) |> trim()
    volume = Map.get(params, :volume, :talk)

    if text != "" and String.length(text) <= @max_speech and volume in @volumes do
      position = Region.get(region, intent.body, :position)

      speech =
        Event.new(:speech,
          entity: intent.body,
          data: %{text: text, volume: volume, position: position}
        )

      said = %{intent | params: %{text: text, volume: volume}}
      {region, [speech, result(said, :success, nil)]}
    else
      {region, [result(intent, :blocked, :invalid)]}
    end
  end

  defp perform(region, %Intent{verb: :stop} = intent, _tick) do
    case complete(region, intent.body, :interrupted, :stopped) do
      {region, []} -> {region, [result(intent, :success, :idle)]}
      {region, stopped} -> {region, stopped ++ [result(intent, :success, nil)]}
    end
  end

  defp perform(region, intent, _tick), do: {region, [result(intent, :blocked, :unknown_verb)]}

  defp travel(region, intent, path, heading) do
    action =
      intent
      |> action_base()
      |> Map.merge(%{path: path, distance: Space.path_length(path), covered: 0.0})

    departed =
      Event.new(:departed, entity: intent.body, data: Map.put(heading, :position, hd(path)))

    start(region, intent.body, action, [departed])
  end

  defp channel_route(%Terrain{} = terrain, here, direction) do
    near = Terrain.near_channel_cells()

    case Terrain.nearest_channel(terrain, here) do
      {index, point, distance} when distance <= near ->
        {:ok, Enum.dedup([here, point | Terrain.path_along(terrain, index, direction)])}

      _far_or_none ->
        {:error, :no_channel}
    end
  end

  defp channel_route(nil, _here, _direction), do: {:error, :no_channel}

  defp follow_direction(%{direction: direction}) when direction in [:upstream, :downstream],
    do: {:ok, direction}

  defp follow_direction(_params), do: {:error, :invalid}

  defp walk_params(%{direction: direction} = params) do
    meters = Map.get(params, :distance_m, 100)

    if direction in Space.directions() and is_integer(meters) and meters in @walk_m,
      do: {:ok, direction, meters},
      else: :error
  end

  defp walk_params(_params), do: :error

  defp map_cells(%Region{terrain: %Terrain{width: width}}), do: width
  defp map_cells(_region), do: @default_map_cells

  defp start(region, body, action, events) do
    {region, replaced} = complete(region, body, :interrupted, :replaced)
    started = Event.new(:action_started, entity: body, data: summary_data(action))
    {Region.put_component(region, body, :action, action), replaced ++ [started | events]}
  end

  defp known_place(region, body, target) do
    knows = Region.get(region, body, :knows) || MapSet.new()

    if is_binary(target) && MapSet.member?(knows, target) && Region.get(region, target, :place) do
      Region.get(region, target, :position)
    end
  end

  defp wait_until(%{for: seconds}, now)
       when is_integer(seconds) and seconds > 0 and seconds <= @max_wait,
       do: {:ok, now + seconds}

  defp wait_until(%{until: moment}, now) do
    case Map.fetch(@moments, moment) do
      {:ok, :sunrise} -> {:ok, Calendar.next(now, Calendar.day(), Daylight.sunrise())}
      {:ok, :sunset} -> {:ok, Calendar.next(now, Calendar.day(), Daylight.sunset())}
      :error -> :error
    end
  end

  defp wait_until(_params, _now), do: :error

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(_other), do: ""

  defp action_base(%Intent{} = intent), do: Map.take(intent, [:ref, :verb, :target, :params])

  defp result(%Intent{} = intent, outcome, reason) do
    finished(intent.body, action_base(intent), outcome, reason)
  end

  defp finished(body, action, outcome, reason) do
    data = action |> summary_data() |> Map.merge(%{outcome: outcome, reason: reason})
    Event.new(:action_result, entity: body, data: data)
  end

  defp summary_data(action), do: Map.take(action, [:ref, :verb, :target, :params])
end
