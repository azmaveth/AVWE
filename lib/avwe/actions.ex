defmodule Avwe.Actions do
  @moduledoc """
  What happens when a controller asks a body to do something. Pure.

  Every intent ends in exactly one `:action_result` event carrying its ref,
  with an outcome from Arbor's vocabulary: `:success`, `:failure`, `:blocked`
  or `:interrupted`.

  Instant actions (speaking, stopping, kindling and dousing a hearth,
  writing in and reading a notebook, taking and releasing control) finish in
  the step they start. Durative actions (going, following, walking,
  waiting) live in the body's `:action` component until a system completes
  them, `:stop` interrupts them, or a new action replaces them. Journeys carry
  a `:path` of waypoints that `Avwe.Systems.Movement` walks along.

  Kindling and dousing act on a hearth within 20 m: the nearest one when the
  intent names no target. They change the hearth at once and emit `:fire_lit`
  or `:fire_out` before the result, so `Avwe.Systems.Fire`, which runs later
  in the same step, burns from the moment of the intent. Those two events
  carry the intent's `ref` beside `by`, so the body's own percept of its
  fire says who asked for it, as its action percepts do.

  Writing and reading act on a notebook the body carries (an item entity
  with `:notebook` and `carried_by`): the one named, or the first by id
  when the intent names none. A page is stamped with the end of the step
  it was written in, the time its result reports, and holds one line of
  plain text: line breaks and tabs become single spaces and other control
  characters are dropped. A read's result carries the pages it read, so
  the reader is told them in the same step.

  Kindling records who lit the hearth (`lit_by`), so that body can tell
  the smoke of its own fire from a stranger's (`Avwe.Systems.Smoke`).
  """

  alias Avwe.{Calendar, Event, Intent, Region, Space, Terrain, Tick}
  alias Avwe.Systems.{Daylight, Fire}

  @volumes [:whisper, :talk, :shout]
  @max_speech 500
  @max_wait 7 * 86_400
  @moments %{dawn: :sunrise, sunrise: :sunrise, dusk: :sunset, sunset: :sunset}
  @default_map_cells 256
  @walk_m 10..2_000
  @max_page 1_000
  @max_pages 500
  @read_last 10
  @read_most 1..50
  # Line breaks and tabs, as regex class members: what a page turns into a space.
  @breaks "\\t\\r\\n\\v\\f\\x{85}\\x{2028}\\x{2029}"

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

  defp perform(region, %Intent{verb: :kindle} = intent, tick) do
    with {:ok, id, hearth, position} <- hearth_target(region, intent),
         :ok <- kindleable(region, id, hearth) do
      lit =
        Map.merge(hearth, %{burning: true, lit_at: tick.time, out_at: nil, lit_by: intent.body})

      event =
        Event.new(:fire_lit,
          entity: id,
          time: tick.time,
          data: %{position: position, by: intent.body, ref: intent.ref}
        )

      {Region.put_component(region, id, :hearth, lit),
       [event, result(%{intent | target: id}, :success, nil)]}
    else
      {:error, reason} -> {region, [result(intent, :blocked, reason)]}
    end
  end

  defp perform(region, %Intent{verb: :douse} = intent, tick) do
    with {:ok, id, hearth, position} <- hearth_target(region, intent),
         :ok <- quenchable(region, id, hearth) do
      out = %{hearth | burning: false, out_at: tick.time}

      event =
        Event.new(:fire_out,
          entity: id,
          time: tick.time,
          data: %{position: position, reason: :doused, by: intent.body, ref: intent.ref}
        )

      {Region.put_component(region, id, :hearth, out),
       [event, result(%{intent | target: id}, :success, nil)]}
    else
      {:error, :unquenchable} -> {region, [result(intent, :failure, :unquenchable)]}
      {:error, reason} -> {region, [result(intent, :blocked, reason)]}
    end
  end

  defp perform(region, %Intent{verb: :write} = intent, tick) do
    case carried_notebook(region, intent) do
      {:ok, id, notebook} ->
        intent = %{intent | target: id}
        text = intent.params |> param(:text) |> clean() |> trim()

        cond do
          text == "" or String.length(text) > @max_page ->
            {region, [result(intent, :blocked, :invalid)]}

          length(notebook.pages) >= @max_pages ->
            {region, [result(intent, :blocked, :full)]}

          true ->
            pages = notebook.pages ++ [%{time: Tick.end_time(tick), text: text}]

            {Region.put_component(region, id, :notebook, %{notebook | pages: pages}),
             [result(%{intent | params: %{text: text}}, :success, nil)]}
        end

      {:error, reason} ->
        {region, [result(intent, :blocked, reason)]}
    end
  end

  defp perform(region, %Intent{verb: :read} = intent, _tick) do
    with {:ok, id, notebook} <- carried_notebook(region, intent),
         {:ok, last} <- read_last(param(intent.params, :last)) do
      read = %{intent | target: id, params: %{last: last}}
      pages = Enum.take(notebook.pages, -last)
      %Event{data: data} = event = result(read, :success, nil)
      {region, [%{event | data: Map.merge(data, %{pages: pages, total: length(notebook.pages)})}]}
    else
      {:error, reason} -> {region, [result(intent, :blocked, reason)]}
    end
  end

  # Control is state (`docs/autopilot-spec.md`, 1): who drives a body is
  # written on it, so the simulation knows and replay reproduces it. Taking
  # what one already holds, or releasing what nobody holds, still succeeds.
  defp perform(region, %Intent{verb: :control, controller: nil} = intent, _tick),
    do: {region, [result(intent, :blocked, :invalid)]}

  defp perform(region, %Intent{verb: :control} = intent, tick) do
    case control(region, intent.body) do
      %{holder: holder} when holder == intent.controller ->
        {region, [result(intent, :success, :already)]}

      _other ->
        taken =
          Event.new(:control_taken, entity: intent.body, data: %{controller: intent.controller})

        {put_control(region, intent.body, intent.controller, tick),
         [taken, result(intent, :success, nil)]}
    end
  end

  defp perform(region, %Intent{verb: :release} = intent, tick) do
    case control(region, intent.body) do
      %{holder: nil} ->
        {region, [result(intent, :success, :already)]}

      %{holder: holder} ->
        released = Event.new(:control_released, entity: intent.body, data: %{controller: holder})
        {put_control(region, intent.body, nil, tick), [released, result(intent, :success, nil)]}
    end
  end

  defp perform(region, intent, _tick), do: {region, [result(intent, :blocked, :unknown_verb)]}

  # The notebook an intent means: the named one if the body carries it, or
  # the first it carries, by id.
  defp carried_notebook(region, %Intent{body: body, target: target}) do
    carried =
      for id <- Region.with_components(region, [:notebook, :carried_by]),
          Region.get(region, id, :carried_by) == body,
          target == nil or id == target,
          do: id

    case carried do
      [id | _more] -> {:ok, id, Region.get(region, id, :notebook)}
      [] -> {:error, :no_notebook}
    end
  end

  defp read_last(nil), do: {:ok, @read_last}
  defp read_last(last) when is_integer(last) and last in @read_most, do: {:ok, last}
  defp read_last(_last), do: {:error, :invalid}

  defp param(%{} = params, key), do: Map.get(params, key)
  defp param(_params, _key), do: nil

  defp control(region, body), do: Region.get(region, body, :control) || %{holder: nil, since: nil}

  defp put_control(region, body, holder, tick),
    do: Region.put_component(region, body, :control, %{holder: holder, since: tick.time})

  # The hearth an intent means: the nearest within reach, or the named one if
  # it is within reach.
  defp hearth_target(region, %Intent{target: nil, body: body}) do
    case Fire.hearth_near(region, Region.get(region, body, :position)) do
      [{id, hearth, _distance} | _rest] -> {:ok, id, hearth, Region.get(region, id, :position)}
      [] -> {:error, :no_hearth}
    end
  end

  defp hearth_target(region, %Intent{target: id, body: body}) do
    here = Region.get(region, body, :position)

    case {Region.get(region, id, :hearth), Region.get(region, id, :position)} do
      {hearth, position} when hearth == nil or position == nil ->
        {:error, :no_such_hearth}

      {hearth, position} ->
        if Space.distance(here, position) <= Fire.at_place_cells(),
          do: {:ok, id, hearth, position},
          else: {:error, :too_far}
    end
  end

  defp kindleable(_region, _id, %{burning: true}), do: {:error, :already_burning}

  defp kindleable(region, id, hearth) do
    if hearth.fuel_kg > 0 or Fire.standing?(region, id), do: :ok, else: {:error, :no_fuel}
  end

  defp quenchable(_region, _id, %{burning: false}), do: {:error, :not_burning}

  defp quenchable(region, id, _hearth) do
    if Fire.unquenchable?(region, id), do: {:error, :unquenchable}, else: :ok
  end

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

  @doc """
  When a wait begun at `now` with these params ends: `for:` seconds (up to
  a week), or the next `until:` moment (`:dawn`, `:sunrise`, `:dusk`,
  `:sunset`). `:error` for anything else, which `:wait` refuses.
  """
  @spec wait_until(map(), Calendar.time()) :: {:ok, Calendar.time()} | :error
  def wait_until(%{for: seconds}, now)
      when is_integer(seconds) and seconds > 0 and seconds <= @max_wait,
      do: {:ok, now + seconds}

  def wait_until(%{until: moment}, now) do
    case Map.fetch(@moments, moment) do
      {:ok, :sunrise} -> {:ok, Calendar.next(now, Calendar.day(), Daylight.sunrise())}
      {:ok, :sunset} -> {:ok, Calendar.next(now, Calendar.day(), Daylight.sunset())}
      :error -> :error
    end
  end

  def wait_until(_params, _now), do: :error

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(_other), do: ""

  # What a page may hold: line breaks and tabs become single spaces, and
  # every other control character (escape codes included) is dropped, so a
  # page can neither forge the lines a reading is told in nor reach a
  # terminal as a command.
  defp clean(text) when is_binary(text) do
    if String.valid?(text) do
      text
      |> String.replace(~r/[ #{@breaks}]*[#{@breaks}][ #{@breaks}]*/u, " ")
      |> String.replace(~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u, "")
    else
      ""
    end
  end

  defp clean(other), do: other

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
