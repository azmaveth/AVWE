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
  silent or start running, and sees its banks begin to steam.

  Heat and fire: a body feels the air and the ground underfoot
  (`Avwe.Systems.Heat.at/2`), the warmth of every fire within 20 m
  (`Avwe.Systems.Fire.felt_all/2`: `warmth.fire` is the strongest,
  `warmth.sources` all of them), and can light or douse a hearth within 20 m.
  `hearths` lists every hearth within 20 m, nearest first; `hearth` is the
  nearest, kept for callers that want one. A fire is its own light: its smoke
  by day or its glow by night shows at least 200 m off, and so do its
  lighting, burning low and going out; those name the hearth unless the body
  is at it. `fires` lists only the fires beyond the spot a body is at (more
  than 20 m off): a burning hearth within 20 m is what is here, and shows in
  `hearths`, not in `fires`. Only the body's own nose smells smoke
  (`Avwe.Systems.Smoke.level_at/3`, the rule the smell percepts follow).
  Smoke smelled at a fire (`Avwe.Systems.Smoke.beside/3`) is that fire's:
  the percept's `source` is the hearth and its summary says the smoke
  rises from it, and the look's `smoke` carries it as `beside: %{id,
  name}`. The smell of a fire the body lit and stands beside is its own:
  its `data` is `%{own_fire: true}`. The snapshot's `fields` carry the heat
  and smoke, and without them `warmth` and `smoke` are `nil`. Steam has one rule, the reach's flag
  (`Avwe.Systems.Heat.steaming?/2`): `warmth.steam?` on a wet cell and
  `channel.steaming` for the river's prose both read it.

  A body's own actions carry who asked for them (`Avwe.Percept`'s
  `issuer`): its controller, or its routine when autopilot had it; so does
  its own lighting or dousing of a hearth, whose `:fire_lit` and
  `:fire_out` events carry the intent's ref. What the body is doing is
  told by who **holds** it, the `holder` of its `:control` component in
  the view (`look/2` carries it as `holder`): its routine's while nobody
  does, the controller's own while one does, whoever asked for it. So the
  waits autopilot issues (an idle, resting or fireside body) are quiet
  while the routine has the body: they raise no percept at all, started,
  under way or ended, so a yielded session is not told every hour that it
  is still waiting, and so is a `go` of the routine's that finds the body
  already there (the nightly step home); the routine's journeys and
  kindling still show. A wait the routine began and the controller
  inherited says when it ends, since they hold the body, and one the
  controller stopped (`:interrupted` with reason `:stopped`) says so, since
  they asked; one their own act replaced (reason `:replaced`) says nothing,
  their act tells the story. The hand-over between the two
  (`:control_released`, `:control_taken`) is a percept of the body's own
  and nobody else's; `:decided` stays the game master's.

  A body's look also lists what it `carried` (a notebook with its page
  count, and the `write` and `read` affordances that go with it) and,
  under `away`, what it remembers of the time nobody held it (`away/2`).
  A notebook's reading is a result percept whose `data` holds the pages.
  """

  alias Avwe.{Event, Percept, Prose, Space, Terrain}
  alias Avwe.Systems.{Fire, Heat, River, Smoke}

  @at_place_cells 2
  @earshot_cells %{whisper: 0.2, talk: 1.5, shout: 10.0}
  @speech_salience %{whisper: 0.8, talk: 0.7, shout: 0.9}
  @own_events [:action_started, :action_progress, :action_result]
  @moving_events [:departed, :arrived]
  @sky_events [:sunrise, :sunset]
  @river_events [:river_silent, :river_flowing]
  @steam_events [:steam_rising, :steam_fading]
  @spring_events [:spring_stopped, :spring_started]
  @fire_events [:fire_lit, :fire_out, :fire_low]
  @smell_events [:smoke_smelled, :smoke_faded]
  @control_events [:control_taken, :control_released]
  @river_cells 12
  @river_salience 0.8
  @steam_salience 0.6
  @fire_sight_cells 20
  @fire_salience %{fire_lit: 0.7, fire_out: 0.6, fire_low: 0.5}
  @smell_salience %{faint: 0.5, clear: 0.7, thick: 0.7}
  @glow_below 0.1
  @away_entries 12

  @doc "How far a body can see, in cells, for a light level from 0.0 to 1.0."
  @spec sight_cells(float()) :: float()
  def sight_cells(light), do: 5 + 45 * light

  @doc """
  What a body senses right now and what it can do. For a spectator (`nil`),
  every body and place in the region. A body's `action` is what it is
  doing (`ref`, `verb`, `target` and its `target_name`, `params`, and for
  a wait `until`, when it ends).
  """
  @spec look(map(), String.t() | nil) :: map()
  def look(view, nil) do
    %{
      spectator: true,
      time: view.time,
      light: light(view),
      bodies: view |> ids(:body) |> Enum.map(&spectated_body(view, &1)),
      places: view |> ids(:place) |> Enum.map(&%{id: &1, name: name(view, &1)}),
      river: river_status(view),
      fires: hearths(view),
      heat: heat_status(view)
    }
  end

  def look(view, body) do
    position = position(view, body)
    here = place_at(view, position)
    action = component(view, :action)[body]
    channel = channel_near(view, position)
    hearths = hearths_here(view, position)
    carried = carried(view, body)

    %{
      spectator: false,
      time: view.time,
      light: light(view),
      body: %{id: body, name: name(view, body)},
      holder: holder(view, body),
      here: here,
      nearest: if(here, do: nil, else: nearest_place(view, body, position)),
      action:
        action &&
          Map.take(action, [:ref, :verb, :target, :params, :until])
          |> Map.put(:target_name, name(view, action.target)),
      ground: view[:terrain] && Terrain.ground(view.terrain, position),
      channel: channel,
      warmth: warmth(view, position),
      smoke: smoke(view, body, position),
      hearth: List.first(hearths),
      hearths: hearths,
      fires: fires_in_sight(view, position),
      bodies: bodies_in_sight(view, body, position),
      places: known_places(view, body, position, here),
      carried: carried,
      away: away(view, body),
      affordances:
        affordances(view, body, here, action, channel, position) ++ notebook_affordances(carried)
    }
  end

  @doc """
  What the body remembers (`Avwe.Systems.Memory`) of the time nobody held
  it: the entries since it was last released (`control.since` while
  `control.holder` is `nil`), or all of them when it was never held, oldest
  first, at most #{@away_entries}. Empty while the body is held.
  """
  @spec away(map(), String.t()) :: [map()]
  def away(view, body) do
    entries = Map.get(component(view, :memory)[body] || %{}, :entries, [])

    case component(view, :control)[body] do
      %{holder: nil, since: nil} ->
        last_away(entries)

      %{holder: nil, since: since} ->
        entries |> Enum.take_while(&(&1.time > since)) |> last_away()

      %{holder: _held} ->
        []

      nil ->
        last_away(entries)
    end
  end

  # Entries are kept newest first.
  defp last_away(entries), do: entries |> Enum.take(@away_entries) |> Enum.reverse()

  @doc "The percepts a body notices among a step's events, in order."
  @spec percepts(map(), String.t() | nil, [Event.t()]) :: [Percept.t()]
  def percepts(view, body, events), do: Enum.flat_map(events, &perceive(view, body, &1))

  defp perceive(view, body, %Event{type: type} = event) when type in @own_events do
    if body != nil and event.entity == body and not quiet?(event.data, holder(view, body)),
      do: [own(view, body, event)],
      else: []
  end

  defp perceive(view, body, %Event{type: :speech} = event), do: hear(view, body, event)

  defp perceive(view, body, %Event{type: type} = event) when type in @moving_events,
    do: see_moving(view, body, event)

  defp perceive(_view, body, %Event{type: type} = event) when type in @sky_events,
    do: [sky(body, event)]

  defp perceive(view, body, %Event{type: type} = event) when type in @river_events,
    do: along_river(view, body, event, {:hearing, @river_salience, &Prose.river/2})

  defp perceive(view, body, %Event{type: type} = event) when type in @steam_events,
    do: along_river(view, body, event, {:sight, @steam_salience, &Prose.steam/2})

  defp perceive(view, body, %Event{type: type} = event) when type in @spring_events,
    do: see_spring(view, body, event)

  defp perceive(view, body, %Event{type: type} = event) when type in @fire_events,
    do: see_fire(view, body, event)

  defp perceive(view, body, %Event{type: type} = event) when type in @smell_events,
    do: smell(view, body, event)

  defp perceive(view, body, %Event{type: :discovered, entity: body} = event) when body != nil,
    do: [discovered(view, body, event)]

  defp perceive(_view, body, %Event{type: type, entity: body} = event)
       when type in @control_events and body != nil,
       do: [hand_over(body, event)]

  defp perceive(_view, _body, _event), do: []

  # Autopilot's waits say nothing while the routine has the body (`holder`
  # is `nil`), nor does its `go` to a place the body is already at; a wait
  # of its own the controller's act replaced says nothing either. One the
  # controller stopped, or inherited and let run out, says so.
  defp quiet?(%{verb: :wait, outcome: :interrupted, reason: :stopped}, _holder), do: false

  defp quiet?(%{verb: :wait, outcome: :interrupted, reason: :replaced, ref: ref}, _holder),
    do: routine?(ref)

  defp quiet?(%{verb: :wait, ref: ref}, nil), do: routine?(ref)

  defp quiet?(%{verb: :go, outcome: :success, reason: :already_there, ref: ref}, nil),
    do: routine?(ref)

  defp quiet?(_data, _holder), do: false

  defp routine?(ref), do: Percept.issuer(ref) == :autopilot

  # Who holds the body in the simulation: its controller's kind, or `nil`
  # when its routine has it.
  defp holder(view, body) do
    case component(view, :control)[body] do
      %{holder: holder} -> holder
      _on_its_own -> nil
    end
  end

  defp own(view, body, %Event{type: :action_started, data: data} = event) do
    %Percept{
      kind: :progress,
      type: :action_started,
      time: event.time,
      body: body,
      intent: data.ref,
      issuer: Percept.issuer(data.ref),
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
      issuer: Percept.issuer(data.ref),
      progress: data.progress,
      salience: 0.3,
      summary: Prose.progress(data.verb, name(view, data.target), data.params, data.progress)
    }
  end

  defp own(
         view,
         body,
         %Event{type: :action_result, data: %{verb: :read, outcome: :success}} = event
       ) do
    %{data: data} = event

    %Percept{
      kind: :result,
      type: :action_result,
      time: event.time,
      body: body,
      intent: data.ref,
      issuer: Percept.issuer(data.ref),
      outcome: :success,
      salience: 1.0,
      data: Map.take(data, [:pages, :total]),
      summary: Prose.read(name(view, data.target), data.pages, data.total)
    }
  end

  defp own(view, body, %Event{type: :action_result, data: data} = event) do
    %Percept{
      kind: :result,
      type: :action_result,
      time: event.time,
      body: body,
      intent: data.ref,
      issuer: Percept.issuer(data.ref),
      outcome: data.outcome,
      reason: data.reason,
      salience: 1.0,
      summary:
        Prose.result(data.verb, data.outcome, data.reason, name(view, data.target), data.params)
    }
  end

  # Only the body itself notices the hand-over between its controller and
  # its routine; `Avwe.Session` passes on the ones its idle rule makes.
  defp hand_over(body, event) do
    %Percept{
      kind: :sensed,
      type: event.type,
      time: event.time,
      body: body,
      salience: 0.3,
      summary: Prose.control(event.type)
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

  # A body notices the river change (its water falling silent, its banks
  # steaming) only for the stretch nearest to it, so walking the bank doesn't
  # bring a string of identical percepts. Spectators notice once per place
  # along it: only when a reach is the first one near a different place from
  # the reach above it. `sense` is the modality, salience and prose of what
  # changed.
  defp along_river(
         %{terrain: %Terrain{} = terrain} = view,
         nil,
         %Event{data: %{reach: k}} = event,
         sense
       ) do
    near = nearest_any_place(view, event.data.position)
    above = if k > 0, do: nearest_any_place(view, Enum.at(Terrain.reaches(terrain), k - 1).mid)

    if near != above, do: [river_percept(nil, event, nil, near, sense)], else: []
  end

  defp along_river(%{terrain: %Terrain{} = terrain} = view, body, event, sense) do
    listener = position(view, body)

    with {index, _point, distance} when distance <= @river_cells <-
           Terrain.nearest_channel(terrain, listener),
         true <- Terrain.reach_of(terrain, index) == event.data.reach do
      source = %{
        ref: River.id(),
        distance_m: Space.meters(distance),
        direction: Space.direction(listener, event.data.position)
      }

      [river_percept(body, event, source, nil, sense)]
    else
      _not_here -> []
    end
  end

  defp along_river(_view, _body, _event, _sense), do: []

  defp river_percept(body, event, source, near, {modality, salience, prose}) do
    %Percept{
      kind: :sensed,
      type: event.type,
      time: event.time,
      body: body,
      modality: modality,
      source: source,
      salience: salience,
      summary: prose.(event.type, near)
    }
  end

  # A fire is its own light: it is seen at least 200 m off whatever the hour.
  # Burning low and going out name the hearth unless the body is at it. The
  # body's own lighting or dousing says who asked for it, as its actions do.
  defp see_fire(view, body, %Event{entity: hearth, data: data} = event) do
    observer = body && position(view, body)
    distance = observer && Space.distance(observer, data.position)

    if body == nil or distance <= max(sight_cells(light(view)), @fire_sight_cells) do
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
                ref: hearth,
                distance_m: Space.meters(distance),
                direction: Space.direction(observer, data.position)
              },
          issuer: own_issuer(body, data),
          salience: @fire_salience[event.type],
          summary:
            Prose.fire(
              event.type,
              who(view, body, Map.get(data, :by)),
              name(view, hearth),
              distance != nil and distance <= @at_place_cells
            )
        }
      ]
    else
      []
    end
  end

  defp who(_view, _body, nil), do: nil
  defp who(_view, body, body), do: :you
  defp who(view, _body, other), do: name(view, other)

  # Who asked for what the body itself did, by the intent's ref.
  defp own_issuer(body, %{by: body, ref: ref}) when body != nil and is_binary(ref),
    do: Percept.issuer(ref)

  defp own_issuer(_body, _data), do: nil

  # Only the body's own nose smells smoke. Smoke smelled at a fire says so:
  # its source is that hearth, and `own_fire` is set when the body lit it.
  defp smell(view, body, %Event{entity: body, data: data} = event) when body != nil do
    level = Map.get(data, :level)
    hearth = Map.get(data, :beside) || Map.get(data, :own_fire)
    beside = hearth && name(view, hearth)

    [
      %Percept{
        kind: :sensed,
        type: event.type,
        time: event.time,
        body: body,
        modality: :smell,
        source: hearth && fire_source(view, body, hearth),
        salience: Map.get(@smell_salience, level, 0.5),
        summary: Prose.smell(event.type, level, Map.get(data, :from), beside),
        data: if(Map.has_key?(data, :own_fire), do: %{own_fire: true})
      }
    ]
  end

  defp smell(_view, _body, _event), do: []

  defp fire_source(view, body, hearth) do
    observer = position(view, body)
    at = position(view, hearth)

    %{
      ref: hearth,
      distance_m: Space.meters(Space.distance(observer, at)),
      direction: Space.direction(observer, at)
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
        reach = Terrain.reach_of(terrain, index)
        state = river_reach(view, reach)

        %{
          distance_m: Space.meters(distance),
          direction: Space.direction(position, point),
          upstream: Terrain.channel_direction(terrain, index, :upstream),
          downstream: Terrain.channel_direction(terrain, index, :downstream),
          at_head: index <= 3,
          at_end: index >= last - 3,
          flowing: state != nil and not state.silent,
          temp_c: state && state.temp_c,
          air_c: Map.get(view.env, :air_c),
          steaming: reach_steaming?(view, reach)
        }

      _far ->
        nil
    end
  end

  defp channel_near(_view, _position), do: nil

  defp reach_steaming?(%{fields: %{heat: %Heat.Field{} = field}}, reach),
    do: Heat.steaming?(field, reach)

  defp reach_steaming?(_view, _reach), do: false

  # Heat, fire and smoke

  defp warmth(view, position) do
    case Heat.at(view, position) do
      nil ->
        nil

      felt ->
        sources =
          view |> Fire.felt_all(position) |> Enum.map(&Map.take(&1, [:ref, :name, :level]))

        Map.merge(felt, %{fire: List.first(sources), sources: sources})
    end
  end

  defp smoke(%{fields: %{smoke: _field}} = view, body, position) do
    case Smoke.level_at(view, position, view.time) do
      :none -> nil
      level -> beside(%{level: level, from: wind(view).from}, view, body, position)
    end
  end

  defp smoke(_view, _body, _position), do: nil

  defp beside(smoke, view, body, position) do
    case Smoke.beside(view, body, position) do
      {hearth, _own?} -> Map.put(smoke, :beside, %{id: hearth, name: name(view, hearth)})
      nil -> smoke
    end
  end

  defp wind(view), do: Map.get(view.env, :wind, Smoke.default_wind())

  # Every hearth within reach, nearest first (then by id).
  defp hearths_here(view, position) do
    for {id, hearth, distance} <- Fire.hearth_near(view, position) do
      %{
        id: id,
        name: name(view, id),
        burning: hearth.burning,
        fuel_kg: hearth.fuel_kg,
        distance_m: Space.meters(distance)
      }
    end
  end

  # The fires beyond this spot that a body can make out: by their smoke in
  # daylight, by their glow at night, at least 200 m off either way. A fire
  # within 20 m is what is here (`hearth_here/2`), not a fire in sight. A
  # standing miracle gives no smoke (`Avwe.Systems.Fire`), so it shows only
  # at night.
  defp fires_in_sight(view, position) do
    light = light(view)
    sight = max(sight_cells(light), @fire_sight_cells)
    sign = if light < @glow_below, do: :glow, else: :smoke

    for source <- Heat.sources(view),
        distance = Space.distance(position, source.position),
        distance > @at_place_cells and distance <= sight,
        sign == :glow or source.kind == :hearth do
      %{
        ref: source.id,
        name: source.name,
        distance_m: Space.meters(distance),
        direction: Space.direction(position, source.position),
        sign: sign
      }
    end
  end

  defp hearths(view) do
    for id <- ids(view, :hearth), hearth = component(view, :hearth)[id] do
      %{id: id, name: name(view, id), burning: hearth.burning, fuel_kg: hearth.fuel_kg}
    end
  end

  defp heat_status(%{fields: %{heat: %Heat.Field{steaming: steaming} = field}} = view) do
    %{
      air_c: Map.get(view.env, :air_c),
      steaming_reaches: Enum.filter(0..(tuple_size(steaming) - 1)//1, &Heat.steaming?(field, &1))
    }
  end

  defp heat_status(_view), do: nil

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

  defp affordances(view, body, here, action, channel, position) do
    known = component(view, :knows)[body] || MapSet.new()
    go = Enum.filter(Enum.sort(MapSet.to_list(known)), &(here == nil or &1 != here.id))

    [
      %{verb: :go, targets: go},
      %{verb: :walk, directions: Space.directions()},
      %{verb: :say, volumes: [:whisper, :talk, :shout]},
      %{verb: :wait, until: [:dawn, :dusk]}
    ] ++
      if(channel, do: [%{verb: :follow, directions: [:upstream, :downstream]}], else: []) ++
      hearth_affordances(view, position) ++
      if(action, do: [%{verb: :stop}], else: [])
  end

  # The items a body carries, by id: for a notebook, how many pages it has.
  defp carried(view, body) do
    for id <- ids(view, :carried_by), component(view, :carried_by)[id] == body do
      item = component(view, :item)[id] || %{}
      notebook = component(view, :notebook)[id]

      %{
        id: id,
        name: name(view, id),
        kind: Map.get(item, :kind),
        pages: notebook && length(notebook.pages)
      }
    end
  end

  defp notebook_affordances(carried) do
    case for(%{kind: :notebook, id: id} <- carried, do: id) do
      [] -> []
      notebooks -> [%{verb: :write, targets: notebooks}, %{verb: :read, targets: notebooks}]
    end
  end

  # Within reach of a hearth, a body can light one that is cold and has fuel
  # (or burns without it) and douse one that is burning and can be put out.
  defp hearth_affordances(view, position) do
    near = Fire.hearth_near(view, position)

    kindle =
      for {id, %{burning: false} = hearth, _distance} <- near,
          hearth.fuel_kg > 0 or Fire.standing?(view, id),
          do: id

    douse =
      for {id, %{burning: true}, _distance} <- near, not Fire.unquenchable?(view, id), do: id

    for {verb, targets} <- [kindle: kindle, douse: douse], targets != [] do
      %{verb: verb, targets: targets}
    end
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
