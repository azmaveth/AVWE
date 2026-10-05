defmodule Avwe.Perception do
  @moduledoc """
  What a body perceives. Pure.

  Works on a region view (`Avwe.Region.view/1`): components, env and time,
  plus the region's terrain under `:terrain` when it has any.

    * `look/2` describes what a body can sense right now and what it can do.
    * `percepts/3` turns a step's events into the percepts a body notices.

  A `nil` body is a spectator, who notices everything and can't act.

  ## Senses

  Sight reaches 50 m at night and about 500 m at noon. Hearing depends on
  volume: a whisper carries 2 m, talk 15 m, a shout 100 m. A body is "at" a
  place within 20 m of it. A body within 80 m of the river channel can see it
  and which way it runs, and within 120 m hears the stretch beside it fall
  silent or start running.
  """

  alias Avwe.{Event, Percept, Prose, Space, Terrain}
  alias Avwe.Systems.River

  @at_place_cells 2
  @earshot_cells %{whisper: 0.2, talk: 1.5, shout: 10.0}
  @speech_salience %{whisper: 0.8, talk: 0.7, shout: 0.9}
  @own_events [:action_started, :action_progress, :action_result]
  @moving_events [:departed, :arrived]
  @sky_events [:sunrise, :sunset]
  @river_events [:river_silent, :river_flowing]
  @spring_events [:spring_stopped, :spring_started]
  @river_cells 12

  @doc "How far a body can see, in cells, for a light level from 0.0 to 1.0."
  @spec sight_cells(float()) :: float()
  def sight_cells(light), do: 5 + 45 * light

  @doc """
  What a body senses right now and what it can do. For a spectator (`nil`),
  every body and place in the region.
  """
  @spec look(map(), String.t() | nil) :: map()
  def look(view, nil) do
    %{
      spectator: true,
      time: view.time,
      light: light(view),
      bodies: view |> ids(:body) |> Enum.map(&spectated_body(view, &1)),
      places: view |> ids(:place) |> Enum.map(&%{id: &1, name: name(view, &1)}),
      river: river_status(view)
    }
  end

  def look(view, body) do
    position = position(view, body)
    here = place_at(view, position)
    action = component(view, :action)[body]
    channel = channel_near(view, position)

    %{
      spectator: false,
      time: view.time,
      light: light(view),
      body: %{id: body, name: name(view, body)},
      here: here,
      nearest: if(here, do: nil, else: nearest_place(view, body, position)),
      action:
        action &&
          Map.take(action, [:ref, :verb, :target, :params])
          |> Map.put(:target_name, name(view, action.target)),
      ground: view[:terrain] && Terrain.ground(view.terrain, position),
      channel: channel,
      bodies: bodies_in_sight(view, body, position),
      places: known_places(view, body, position, here),
      affordances: affordances(view, body, here, action, channel)
    }
  end

  @doc "The percepts a body notices among a step's events, in order."
  @spec percepts(map(), String.t() | nil, [Event.t()]) :: [Percept.t()]
  def percepts(view, body, events), do: Enum.flat_map(events, &perceive(view, body, &1))

  defp perceive(view, body, %Event{type: type} = event) when type in @own_events do
    if body != nil and event.entity == body, do: [own(view, body, event)], else: []
  end

  defp perceive(view, body, %Event{type: :speech} = event), do: hear(view, body, event)

  defp perceive(view, body, %Event{type: type} = event) when type in @moving_events,
    do: see_moving(view, body, event)

  defp perceive(_view, body, %Event{type: type} = event) when type in @sky_events,
    do: [sky(body, event)]

  defp perceive(view, body, %Event{type: type} = event) when type in @river_events,
    do: hear_river(view, body, event)

  defp perceive(view, body, %Event{type: type} = event) when type in @spring_events,
    do: see_spring(view, body, event)

  defp perceive(view, body, %Event{type: :discovered, entity: body} = event) when body != nil,
    do: [discovered(view, body, event)]

  defp perceive(_view, _body, _event), do: []

  defp own(view, body, %Event{type: :action_started, data: data} = event) do
    %Percept{
      kind: :progress,
      type: :action_started,
      time: event.time,
      body: body,
      intent: data.ref,
      progress: 0.0,
      salience: 0.3,
      summary: Prose.started(data.verb, name(view, data.target), data.params)
    }
  end

  defp own(view, body, %Event{type: :action_progress, data: data} = event) do
    %Percept{
      kind: :progress,
      type: :action_progress,
      time: event.time,
      body: body,
      intent: data.ref,
      progress: data.progress,
      salience: 0.3,
      summary: Prose.progress(data.verb, name(view, data.target), data.params, data.progress)
    }
  end

  defp own(view, body, %Event{type: :action_result, data: data} = event) do
    %Percept{
      kind: :result,
      type: :action_result,
      time: event.time,
      body: body,
      intent: data.ref,
      outcome: data.outcome,
      reason: data.reason,
      salience: 1.0,
      summary:
        Prose.result(data.verb, data.outcome, data.reason, name(view, data.target), data.params)
    }
  end

  defp hear(_view, body, %Event{entity: body}) when body != nil, do: []

  defp hear(view, nil, %Event{entity: speaker, data: data} = event) do
    [
      speech_percept(
        nil,
        event,
        nil,
        Prose.heard(name(view, speaker), data.volume, data.text, nil)
      )
    ]
  end

  defp hear(view, body, %Event{entity: speaker, data: data} = event) do
    listener = position(view, body)
    distance = Space.distance(listener, data.position)

    if distance <= @earshot_cells[data.volume] do
      in_sight? = distance <= sight_cells(light(view))
      direction = if distance > @earshot_cells.talk, do: Space.direction(listener, data.position)
      who = if in_sight?, do: name(view, speaker), else: "Someone"
      source = %{ref: speaker, distance_m: Space.meters(distance), direction: direction}

      percept =
        speech_percept(body, event, source, Prose.heard(who, data.volume, data.text, direction))

      [%{percept | confidence: if(in_sight?, do: 1.0, else: 0.6)}]
    else
      []
    end
  end

  defp speech_percept(body, event, source, summary) do
    %Percept{
      kind: :sensed,
      type: :speech,
      time: event.time,
      body: body,
      modality: :hearing,
      source: source,
      salience: @speech_salience[event.data.volume],
      summary: summary
    }
  end

  defp see_moving(_view, body, %Event{entity: body}) when body != nil, do: []

  defp see_moving(view, body, %Event{entity: mover, data: data} = event) do
    observer = body && position(view, body)
    distance = observer && Space.distance(observer, data.position)

    if body == nil or distance <= sight_cells(light(view)) do
      place = name(view, data[:place] || data[:toward]) || data[:heading]

      [
        %Percept{
          kind: :sensed,
          type: event.type,
          time: event.time,
          body: body,
          modality: :sight,
          source:
            distance &&
              %{
                ref: mover,
                distance_m: Space.meters(distance),
                direction: Space.direction(observer, data.position)
              },
          salience: 0.5,
          summary:
            Prose.moving(event.type, name(view, mover), place, Map.has_key?(data, :heading))
        }
      ]
    else
      []
    end
  end

  # A body hears the river change only for the stretch nearest to it, so
  # walking the bank doesn't bring a string of identical percepts.
  # Spectators hear about the river once per place along it: only when a reach
  # is the first one near a different place from the reach above it.
  defp hear_river(%{terrain: %Terrain{} = terrain} = view, nil, %Event{data: %{reach: k}} = event) do
    near = nearest_any_place(view, event.data.position)
    above = if k > 0, do: nearest_any_place(view, Enum.at(Terrain.reaches(terrain), k - 1).mid)

    if near != above,
      do: [river_percept(nil, event, nil, Prose.river(event.type, near))],
      else: []
  end

  defp hear_river(%{terrain: %Terrain{} = terrain} = view, body, event) do
    listener = position(view, body)

    with {index, _point, distance} when distance <= @river_cells <-
           Terrain.nearest_channel(terrain, listener),
         true <- Terrain.reach_of(terrain, index) == event.data.reach do
      source = %{
        ref: River.id(),
        distance_m: Space.meters(distance),
        direction: Space.direction(listener, event.data.position)
      }

      [river_percept(body, event, source, Prose.river(event.type, nil))]
    else
      _not_here -> []
    end
  end

  defp hear_river(_view, _body, _event), do: []

  defp river_percept(body, event, source, summary) do
    %Percept{
      kind: :sensed,
      type: event.type,
      time: event.time,
      body: body,
      modality: :hearing,
      source: source,
      salience: 0.8,
      summary: summary
    }
  end

  defp see_spring(view, body, event) do
    observer = body && position(view, body)

    if body == nil or Space.distance(observer, event.data.position) <= sight_cells(light(view)) do
      [
        %Percept{
          kind: :sensed,
          type: event.type,
          time: event.time,
          body: body,
          modality: :sight,
          salience: 0.9,
          summary: Prose.spring(event.type)
        }
      ]
    else
      []
    end
  end

  defp discovered(view, body, %Event{data: %{place: place}} = event) do
    %Percept{
      kind: :sensed,
      type: :discovered,
      time: event.time,
      body: body,
      modality: :sight,
      source: %{ref: place},
      salience: 0.9,
      summary: Prose.discovered(name(view, place), description(view, place))
    }
  end

  defp channel_near(%{terrain: %Terrain{} = terrain} = view, position) do
    near = Terrain.near_channel_cells()

    case Terrain.nearest_channel(terrain, position) do
      {index, point, distance} when distance <= near ->
        last = tuple_size(terrain.channel) - 1
        state = river_reach(view, Terrain.reach_of(terrain, index))

        %{
          distance_m: Space.meters(distance),
          direction: Space.direction(position, point),
          upstream: Terrain.channel_direction(terrain, index, :upstream),
          downstream: Terrain.channel_direction(terrain, index, :downstream),
          at_head: index <= 3,
          at_end: index >= last - 3,
          flowing: state != nil and not state.silent,
          temp_c: state && state.temp_c
        }

      _far ->
        nil
    end
  end

  defp channel_near(_view, _position), do: nil

  defp river_reach(view, reach) do
    case component(view, :river)[River.id()] do
      %{reaches: reaches} when tuple_size(reaches) > reach -> elem(reaches, reach)
      _no_river -> nil
    end
  end

  defp river_status(view) do
    case component(view, :river)[River.id()] do
      %{reaches: reaches} when tuple_size(reaches) > 0 ->
        states = Tuple.to_list(reaches)

        %{
          name: name(view, River.id()),
          flowing: Enum.count(states, &(not &1.silent)),
          reaches: length(states)
        }

      _no_river ->
        nil
    end
  end

  defp sky(body, event) do
    %Percept{
      kind: :sensed,
      type: event.type,
      time: event.time,
      body: body,
      modality: :sight,
      salience: 0.2,
      summary: Prose.sky(event.type)
    }
  end

  defp bodies_in_sight(view, body, position) do
    sight = sight_cells(light(view))

    for other <- ids(view, :body),
        other != body,
        other_position = position(view, other),
        distance = Space.distance(position, other_position),
        distance <= sight do
      %{
        id: other,
        name: name(view, other),
        here: distance <= @at_place_cells,
        distance_m: Space.meters(distance),
        direction: Space.direction(position, other_position)
      }
    end
  end

  defp known_places(view, body, position, here) do
    knows = component(view, :knows)[body] || MapSet.new()

    for place <- ids(view, :place),
        MapSet.member?(knows, place),
        here == nil or place != here.id do
      place_position = position(view, place)

      %{
        id: place,
        name: name(view, place),
        distance_m: Space.meters(Space.distance(position, place_position)),
        direction: Space.direction(position, place_position)
      }
    end
    |> Enum.sort_by(& &1.name)
  end

  defp affordances(view, body, here, action, channel) do
    known = component(view, :knows)[body] || MapSet.new()
    go = Enum.filter(Enum.sort(MapSet.to_list(known)), &(here == nil or &1 != here.id))

    [
      %{verb: :go, targets: go},
      %{verb: :walk, directions: Space.directions()},
      %{verb: :say, volumes: [:whisper, :talk, :shout]},
      %{verb: :wait, until: [:dawn, :dusk]}
    ] ++
      if(channel, do: [%{verb: :follow, directions: [:upstream, :downstream]}], else: []) ++
      if(action, do: [%{verb: :stop}], else: [])
  end

  defp spectated_body(view, body) do
    position = position(view, body)
    action = component(view, :action)[body]
    here = place_at(view, position)

    %{
      id: body,
      name: name(view, body),
      at: here && here.name,
      near: if(here, do: nil, else: nearest_any_place(view, position)),
      going_to: action && action.verb == :go && name(view, action.target)
    }
  end

  defp place_at(view, position) do
    view
    |> ids(:place)
    |> Enum.map(&{&1, Space.distance(position, position(view, &1))})
    |> Enum.filter(fn {_place, distance} -> distance <= @at_place_cells end)
    |> Enum.min_by(fn {_place, distance} -> distance end, fn -> nil end)
    |> case do
      nil ->
        nil

      {place, _distance} ->
        %{id: place, name: name(view, place), description: description(view, place)}
    end
  end

  defp nearest_place(view, body, position) do
    knows = component(view, :knows)[body] || MapSet.new()

    view
    |> ids(:place)
    |> Enum.filter(&MapSet.member?(knows, &1))
    |> nearest(view, position)
  end

  defp nearest_any_place(view, position) do
    case view |> ids(:place) |> nearest(view, position) do
      nil -> nil
      nearest -> nearest.name
    end
  end

  defp nearest([], _view, _position), do: nil

  defp nearest(places, view, position) do
    place = Enum.min_by(places, &Space.distance(position, position(view, &1)))
    place_position = position(view, place)

    %{
      id: place,
      name: name(view, place),
      distance_m: Space.meters(Space.distance(place_position, position)),
      direction: Space.direction(place_position, position)
    }
  end

  defp light(view), do: Map.get(view.env, :light, 0.0)
  defp component(view, name), do: Map.get(view.components, name, %{})
  defp ids(view, name), do: view |> component(name) |> Map.keys() |> Enum.sort()
  defp position(view, id), do: component(view, :position)[id]

  defp name(_view, nil), do: nil

  defp name(view, id) do
    case component(view, :repr)[id] do
      %{name: name} when is_binary(name) -> name
      _no_name -> id
    end
  end

  defp description(view, id) do
    case component(view, :repr)[id] do
      %{description: description} -> description
      _no_description -> nil
    end
  end
end
