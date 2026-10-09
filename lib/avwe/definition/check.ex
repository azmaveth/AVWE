defmodule Avwe.Definition.Check do
  @moduledoc """
  What a decoded definition (`Avwe.Definition`) says that its shapes cannot:
  an id belongs to one thing, and every id a section names is something in the
  world. All problems are reported, in plain words, each with the path to it
  in the file. Pure.

  A place is an entity with a `place` component; the river's source, made by
  `Avwe.Worldgen` from the terrain, is one as well once the world is built. The
  terrain is generated before anything else is placed, so it can name only the
  places of `entities`.
  """

  alias Avwe.Definition
  alias Avwe.Definition.Schema
  alias Avwe.Ruleset
  alias Avwe.Systems.River
  alias Avwe.Worldgen

  @doc "Every problem with the definition's references, or `[]`."
  @spec problems(Definition.t()) :: [String.t()]
  def problems(%Definition{} = definition) do
    world = world(definition)

    Enum.flat_map(
      [
        &ruleset/2,
        &ids/2,
        &entities/2,
        &terrain/2,
        &hearths/2,
        &miracles/2,
        &characters/2,
        &guests/2
      ],
      & &1.(definition, world)
    )
  end

  # The rules the world runs make a world (`Avwe.Ruleset`), and the rules the
  # file tells things to are among them.
  defp ruleset(definition, _world) do
    case Ruleset.resolve(definition.ruleset) do
      {:ok, modules} ->
        listed = MapSet.new(modules, & &1.id())

        composition(modules) ++
          not_run(definition, listed) ++
          ruleset_problems(Definition.unserved(definition, modules))

      {:error, problems} ->
        ruleset_problems(problems)
    end
  end

  defp composition(modules) do
    case Ruleset.plan(modules) do
      {:ok, _plan} -> []
      {:error, problems} -> ruleset_problems(problems)
    end
  end

  defp ruleset_problems(problems), do: Enum.map(problems, &("ruleset: " <> &1))

  defp not_run(definition, listed) do
    for {rule, _parameters} <- Enum.sort(told(definition)), rule not in listed do
      "rules.#{rule}: this world does not run that rule"
    end
  end

  # The rules the file gives parameters to, by id.
  defp told(definition) do
    settings = definition.settings

    [
      {"earthlike.valley", Keyword.get(settings, :terrain)},
      {"earthlike.fire", Keyword.get(settings, :hearths)},
      {"earthlike.weather", Keyword.get(settings, :climate)}
    ]
    |> Enum.reject(fn {_rule, parameters} -> parameters in [nil, []] end)
    |> Map.new()
  end

  # What exists once the world is built, by kind.
  defp world(definition) do
    entities = Map.new(definition.entities)
    source = definition |> river() |> Keyword.get(:source, []) |> Keyword.get(:id)

    standing =
      for miracle <- miracles_of(definition), miracle[:kind] == :standing, do: miracle[:id]

    hearths = for hearth <- hearths_of(definition), do: hearth[:id]

    places = for {id, %{place: _label}} <- definition.entities, do: id

    items =
      for {_body, spec} <- characters_of(definition),
          item <- spec[:carries] || [],
          do: item[:id]

    %{
      entities: entities,
      places: MapSet.new(places),
      bodies: MapSet.new(for {id, %{body: _body}} <- definition.entities, do: id),
      source: source,
      hearths: hearths,
      standing: standing,
      items: items,
      everything:
        MapSet.new(
          Map.keys(entities) ++
            hearths ++ standing ++ items ++ miracle_ids(definition) ++ List.wrap(source)
        )
    }
  end

  defp river(definition), do: definition.settings |> terrain_of() |> Keyword.get(:river, [])
  defp terrain_of(settings), do: Keyword.get(settings, :terrain) || []
  defp hearths_of(definition), do: Keyword.get(definition.settings, :hearths) || []
  defp miracles_of(definition), do: Keyword.get(definition.settings, :miracles) || []
  defp characters_of(definition), do: Keyword.get(definition.settings, :characters) || []
  defp miracle_ids(definition), do: for(miracle <- miracles_of(definition), do: miracle[:id])

  # Ids: each belongs to one thing

  defp ids(definition, world) do
    entity_claims = for {id, _components} <- definition.entities, do: {id, "an entity"}
    hearth_claims = for id <- world.hearths, do: {id, "a hearth"}
    miracle_claims = for id <- miracle_ids(definition), do: {id, "a miracle"}
    item_claims = for id <- world.items, do: {id, "a carried item"}

    river_claims =
      if world.source,
        do: [{world.source, "the river's source"}, {River.id(), "the river"}],
        else: []

    (entity_claims ++ hearth_claims ++ miracle_claims ++ item_claims ++ river_claims)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_id, claims} -> length(claims) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {id, claims} ->
      "id #{inspect(id)} is used more than once: #{claims |> Enum.sort() |> Enum.join(", ")}"
    end)
  end

  # Entities

  defp entities(definition, world) do
    Enum.flat_map(definition.entities, fn {id, components} ->
      where = "entities#{key(id)}"

      position(where, components) ++
        place_reference(where <> ".home", components[:home], world.places) ++
        knowledge(where <> ".knows", components[:knows], world.places)
    end)
  end

  defp position(where, %{place: _label} = components) when not is_map_key(components, :position),
    do: ["#{where}: a place needs a position"]

  defp position(where, %{position: {x, y}}) do
    grid = Worldgen.grid()

    if x in 0..(grid - 1) and y in 0..(grid - 1),
      do: [],
      else: ["#{where}.position: [#{x}, #{y}] is off the map (cells 0 to #{grid - 1})"]
  end

  defp position(_where, _components), do: []

  defp knowledge(_where, nil, _places), do: []

  defp knowledge(where, knows, places) do
    for id <- Enum.sort(knows),
        not MapSet.member?(places, id),
        do: "#{where}: #{inspect(id)} is not a place of this world"
  end

  # Terrain: generated first, so only the places of `entities` exist

  defp terrain(definition, world) do
    terrain = terrain_of(definition.settings)
    where = "rules.earthlike.valley"

    river_places(where <> ".river", Keyword.get(terrain, :river), world.places) ++
      listed_places(where <> ".rises", Keyword.get(terrain, :rises, []), world.places) ++
      listed_places(where <> ".clay", Keyword.get(terrain, :clay, []), world.places)
  end

  defp river_places(_where, nil, _places), do: []

  defp river_places(where, river, places) do
    through =
      river
      |> Keyword.get(:through, [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {waypoint, index} ->
        place_reference("#{where}.through[#{index}]", waypoint_place(waypoint), places)
      end)

    place_reference(where <> ".source.from", river[:source][:from], places) ++ through
  end

  defp waypoint_place({place, _options}), do: place
  defp waypoint_place(place), do: place

  defp listed_places(where, entries, places) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {{place, _options}, index} ->
      place_reference("#{where}[#{index}]", place, places)
    end)
  end

  # Hearths and miracles

  defp hearths(definition, world) do
    places = with_source(world)

    for hearth <- hearths_of(definition),
        problem <-
          place_reference(
            "rules.earthlike.fire.hearths#{key(hearth[:id])}.at",
            hearth[:at],
            places
          ),
        do: problem
  end

  defp miracles(definition, world) do
    Enum.flat_map(miracles_of(definition), fn miracle ->
      where = "miracles#{key(miracle[:id])}"

      case miracle[:kind] do
        :standing -> place_reference(where <> ".at", miracle[:at], with_source(world))
        :event -> event(where, miracle, world)
      end
    end)
  end

  defp event(where, miracle, world) do
    target(where <> ".target", miracle[:target], miracle[:component], world) ++
      settable(where <> ".set", miracle[:component], Map.keys(miracle[:set]))
  end

  defp target(where, target, component, world) do
    cond do
      not MapSet.member?(world.everything, target) ->
        ["#{where}: #{inspect(target)} is not in this world"]

      component == :spring and target != world.source ->
        ["#{where}: #{inspect(target)} has no spring (only the river's source has)"]

      component == :hearth and target not in (world.hearths ++ world.standing) ->
        ["#{where}: #{inspect(target)} is not a hearth"]

      true ->
        []
    end
  end

  defp settable(where, component, keys) do
    for key <- Enum.sort(keys),
        key not in Schema.set_keys(component),
        do: "#{where}: #{key} cannot be set on a #{component}"
  end

  # Characters

  defp characters(definition, world) do
    Enum.flat_map(characters_of(definition), fn {id, spec} ->
      where = "characters#{key(id)}"

      if MapSet.member?(world.bodies, id),
        do: routine(where <> ".routine", spec[:routine] || [], world.everything),
        else: ["#{where}: #{inspect(id)} is not a body of this world"]
    end)
  end

  defp routine(where, entries, everything) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, entry_index} ->
      entry[:do]
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, step_index} ->
        step_target("#{where}[#{entry_index}].do[#{step_index}]", step, everything)
      end)
    end)
  end

  defp step_target(where, {_verb, options}, everything) do
    case options[:target] do
      nil ->
        []

      target ->
        if MapSet.member?(everything, target),
          do: [],
          else: ["#{where}.target: #{inspect(target)} is not in this world"]
    end
  end

  defp step_target(_where, {_verb}, _everything), do: []

  # Guests

  defp guests(%Definition{guests: nil}, _world), do: []

  defp guests(%Definition{guests: guests}, world),
    do: place_reference("guests.arrival", guests[:arrival], with_source(world))

  # Helpers

  defp with_source(%{source: nil, places: places}), do: places
  defp with_source(%{source: source, places: places}), do: MapSet.put(places, source)

  defp place_reference(_where, nil, _places), do: []

  defp place_reference(where, id, places) do
    if MapSet.member?(places, id),
      do: [],
      else: ["#{where}: #{inspect(id)} is not a place of this world"]
  end

  defp key(id), do: "[#{inspect(id)}]"
end
