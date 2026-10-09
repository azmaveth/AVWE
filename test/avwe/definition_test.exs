defmodule Avwe.DefinitionTest do
  use ExUnit.Case, async: true

  alias Avwe.{Definition, Definitions, Region}
  alias Avwe.Test.Fixtures

  @moduletag :tmp_dir

  # A small world, as JSON would give it: two places, one body, one hearth, the
  # terrain, a miracle of each kind, a routine, a guest door.
  defp tiny do
    %{
      "schema" => 1,
      "id" => "tiny",
      "name" => "Tiny",
      "tagline" => "A world of two places.",
      "seed" => 7,
      "start" => %{"year" => 1, "day" => 3, "hour" => 6},
      "entities" => [
        place("green", "The Green", [10, 10]),
        place("pond", "The Pond", [30, 10]),
        %{
          "id" => "wren",
          "body" => %{"species" => nil},
          "repr" => %{"name" => "Wren", "description" => "A girl."},
          "knows" => ["green", "pond"],
          "home" => "green",
          "position" => [10, 10]
        }
      ],
      "rules" => %{
        "earthlike.valley" => %{
          "river" => %{
            "name" => "the Brook",
            "flow_m3_s" => 1.0,
            "water_c" => 12.0,
            "source" => %{
              "id" => "brook-head",
              "name" => "The Head",
              "from" => "pond",
              "bearing" => [20, 70],
              "cells" => [10, 12]
            },
            "through" => ["pond", %{"place" => "green", "beside" => "east", "cells" => 3}],
            "exit" => "south"
          },
          "rises" => [%{"place" => "green", "height_m" => 4, "radius_cells" => 5}]
        },
        "earthlike.fire" => %{
          "hearths" => [
            %{
              "id" => "hearth",
              "name" => "the hearth",
              "at" => "green",
              "fuel_kg" => 5.0,
              "power_w" => 3000.0
            }
          ]
        },
        "earthlike.weather" => %{"wind" => %{"from" => "north", "m_s" => 1.5}}
      },
      "miracles" => [
        %{
          "id" => "brook-fails",
          "kind" => "event",
          "at" => %{"year" => 1, "day" => 2},
          "target" => "brook-head",
          "component" => "spring",
          "set" => %{"flow_m3_s" => 0.0}
        },
        %{
          "id" => "ember",
          "name" => "The Ember",
          "kind" => "standing",
          "at" => "green",
          "heat_w" => 500.0,
          "breaks" => ["fuel"]
        }
      ],
      "characters" => %{
        "wren" => %{
          "norms" => ["invited_fire"],
          "carries" => [%{"id" => "wren-book", "kind" => "notebook", "name" => "a book"}],
          "routine" => [
            %{
              "at" => "07:30",
              "do" => [%{"verb" => "go", "target" => "pond"}, %{"verb" => "rest"}],
              "note" => "to the pond"
            }
          ],
          "glyph" => "W",
          "color" => "#aa8800"
        }
      },
      "guests" => %{"arrival" => "green", "max" => 3}
    }
  end

  defp place(id, label, position) do
    %{
      "id" => id,
      "place" => %{"label" => label},
      "position" => position,
      "repr" => %{"name" => label, "description" => nil},
      "article" => nil
    }
  end

  defp decode!(json) do
    assert {:ok, definition} = Definition.decode(json)
    definition
  end

  defp problems(json) do
    assert {:error, problems} = Definition.decode(json)
    problems
  end

  defp with_entity(json, id, change),
    do: update_in(json, ["entities"], &Enum.map(&1, fn entity -> changed(entity, id, change) end))

  defp changed(%{"id" => id} = entity, id, change), do: change.(entity)
  defp changed(entity, _id, _change), do: entity

  describe "reading" do
    test "a definition is read from the terms of its JSON" do
      definition = decode!(tiny())

      assert %Definition{id: "tiny", name: "Tiny", tagline: "A world of two places.", seed: 7} =
               definition

      assert definition.start == {1, day: 3, hour: 6}
      assert definition.dt == 60
      assert definition.guests == [arrival: "green", max: 3]
      assert Enum.map(definition.entities, &elem(&1, 0)) == ["green", "pond", "wren"]

      assert Keyword.keys(definition.settings) == [
               :terrain,
               :hearths,
               :miracles,
               :climate,
               :characters
             ]

      assert definition.settings[:climate] == [wind: [from: "north", m_s: 1.5]]
    end

    test "only what the file says is there: a world needs little" do
      json = %{"schema" => 1, "id" => "bare", "name" => "Bare", "seed" => 1, "start" => 0}
      definition = decode!(json)

      assert definition.entities == []
      assert definition.settings == []
      assert definition.guests == nil
      assert definition.tagline == nil
    end

    test "a miracle is an event or a standing one, by its kind" do
      definition = decode!(tiny())
      [event, standing] = definition.settings[:miracles]

      assert event[:kind] == :event and event[:target] == "brook-head"
      assert event[:set] == %{flow_m3_s: 0.0}
      assert event[:at] == {1, day: 2}
      assert standing[:kind] == :standing and standing[:name] == "The Ember"
      assert standing[:breaks] == [:fuel]
    end

    test "a file that is not JSON, or not an object, is refused in a sentence" do
      assert {:error, [problem]} = Definition.from_json("{\"schema\": ")
      assert problem =~ "the file is not JSON"

      assert problems([1, 2]) == ["the file: expected an object, got [1, 2]"]
    end

    test "a file can be read from its text" do
      assert {:ok, %Definition{id: "tiny"}} = Definition.from_json(JSON.encode!(tiny()))
    end

    test "explain says the other reasons in words too" do
      assert Definition.explain({:read_definition, "/x.json", :enoent}) =~
               "cannot read the definition /x.json: no such file or directory"

      assert Definition.explain({:bad_definition_name, "../x"}) =~
               ~s("../x" is not a definition name)

      assert Definition.explain(:definition_and_quire) ==
               "a world is started from a definition or from a Quire folder, not both"

      assert Definition.explain(:no_world_source) =~ "a world needs a definition"

      assert Definition.explain({:settings_with_definition, [:start, :seed]}) ==
               ":start, :seed cannot be given beside a definition: " <>
                 "the definition is the whole of the world, so change the definition"

      assert Definition.explain(:something_else) == ":something_else"
    end
  end

  describe "what a definition may name" do
    test "an unknown key is refused wherever it is" do
      json =
        tiny()
        |> Map.put("colour", "red")
        |> put_in(["rules", "earthlike.weather", "wind", "gusts"], 3)

      assert problems(json) == [
               ~s|colour: not a key of this (it has "schema", "id", "name", "tagline", "description", "seed", "dt", "start", "rules", "entities", "miracles", "characters", "guests")|,
               ~s|rules.earthlike.weather.wind.gusts: not a key of this (it has "from", "m_s")|
             ]
    end

    test "a rule the engine does not have is refused" do
      assert [problem] = problems(put_in(tiny(), ["rules", "earthlike.magic"], %{}))
      assert problem =~ "rules.earthlike.magic: not a key of this"
    end

    test "a verb, a component, a norm, an item kind or a direction not in the lists is refused" do
      json =
        tiny()
        |> put_in(
          ["characters", "wren", "routine", Access.at(0), "do", Access.at(0), "verb"],
          "fly"
        )
        |> put_in(["characters", "wren", "norms"], ["tithe"])
        |> put_in(["characters", "wren", "carries", Access.at(0), "kind"], "sword")
        |> put_in(["miracles", Access.at(0), "component"], "moon")
        |> put_in(["rules", "earthlike.valley", "river", "exit"], "up")
        |> put_in(["rules", "earthlike.weather", "wind", "from"], "inward")

      problems = problems(json)

      assert length(problems) == 6
      assert Enum.any?(problems, &(&1 =~ ~s(routine[0].do[0].verb: expected one of "go")))
      assert Enum.any?(problems, &(&1 =~ ~s(norms[0]: expected one of "invited_fire")))
      assert Enum.any?(problems, &(&1 =~ ~s(carries[0].kind: expected one of "notebook")))

      assert Enum.any?(
               problems,
               &(&1 =~ ~s(miracles[0].component: expected one of "spring", "hearth"))
             )

      assert Enum.any?(
               problems,
               &(&1 =~ ~s(river.exit: expected one of "north", "east", "south", "west"))
             )

      assert Enum.any?(
               problems,
               &(&1 =~ "wind.from: expected a compass direction (north, north-east")
             )
    end

    test "a miracle must be an event or a standing one" do
      json = put_in(tiny(), ["miracles", Access.at(0), "kind"], "wonder")

      assert problems(json) == [
               ~s(miracles[0].kind: expected one of "event", "standing", got "wonder")
             ]

      json = update_in(tiny(), ["miracles", Access.at(1)], &Map.delete(&1, "kind"))

      assert [~s(miracles[1].kind: expected one of "event", "standing", got nil)] ==
               problems(json)
    end

    test "a value out of range is refused, with what was wanted" do
      json =
        tiny()
        |> put_in(["rules", "earthlike.fire", "hearths", Access.at(0), "fuel_kg"], -1.0)
        |> put_in(["rules", "earthlike.fire", "hearths", Access.at(0), "power_w"], 0)
        |> put_in(["rules", "earthlike.weather", "wind", "m_s"], -2)
        |> put_in(["guests", "max"], 0)
        |> put_in(["dt"], 0)
        |> put_in(["characters", "wren", "routine", Access.at(0), "at"], "25:00")
        |> put_in(["characters", "wren", "color"], "red")
        |> put_in(["characters", "wren", "glyph"], "WW")
        |> put_in(["miracles", Access.at(1), "heat_w"], 0)

      problems = problems(json)

      assert length(problems) == 9

      assert "rules.earthlike.fire.hearths[0].fuel_kg: expected a number, 0 or more, got -1.0" in problems

      assert "rules.earthlike.fire.hearths[0].power_w: expected a number above 0, got 0" in problems

      assert "rules.earthlike.weather.wind.m_s: expected a number, 0 or more, got -2" in problems
      assert "guests.max: expected a whole number above 0, got 0" in problems
      assert "dt: expected a whole number above 0, got 0" in problems

      assert ~s(characters["wren"].routine[0].at: expected a time of day like "04:30", got "25:00") in problems

      assert ~s(characters["wren"].color: expected a colour like "#aa8800", got "red") in problems
      assert ~s(characters["wren"].glyph: expected one printable character, got "WW") in problems
      assert "miracles[1].heat_w: expected a number above 0, got 0" in problems
    end

    test "a routine needs a step, and a miracle something to set" do
      json =
        tiny()
        |> put_in(["characters", "wren", "routine", Access.at(0), "do"], [])
        |> put_in(["miracles", Access.at(0), "set"], %{})

      assert problems(json) == [
               ~s(miracles[0].set: expected at least one value to set, got %{}),
               ~s(characters["wren"].routine[0].do: expected a list of steps, at least one, got [])
             ]
    end

    test "a time is a date on the clock" do
      json = put_in(tiny(), ["start"], %{"year" => 1, "day" => 0})
      assert problems(json) == ["start.day: expected a day of the year, 1 or more, got 0"]
    end
  end

  describe "what a definition says of itself" do
    test "an id belongs to one thing" do
      json =
        tiny()
        |> update_in(["entities"], &(&1 ++ [place("hearth", "Hearth Hill", [5, 5])]))
        |> put_in(["miracles", Access.at(1), "id"], "brook-head")

      assert problems(json) == [
               ~s(id "brook-head" is used more than once: a miracle, the river's source),
               ~s(id "hearth" is used more than once: a hearth, an entity)
             ]
    end

    test "the river is an id too, once there is a river" do
      json = update_in(tiny(), ["entities"], &(&1 ++ [place("river", "The River", [5, 5])]))
      assert problems(json) == [~s(id "river" is used more than once: an entity, the river)]
    end

    test "a place needs a position, on the map" do
      json =
        update_in(
          tiny(),
          ["entities"],
          &(&1 ++ [Map.delete(place("hill", "Hill", [0, 0]), "position")])
        )

      assert problems(json) == [~s(entities["hill"]: a place needs a position)]

      json = with_entity(tiny(), "pond", &Map.put(&1, "position", [300, 5]))

      assert problems(json) == [
               ~s|entities["pond"].position: [300, 5] is off the map (cells 0 to 255)|
             ]
    end

    test "where a body lives and what it knows must be places" do
      json =
        with_entity(tiny(), "wren", fn wren ->
          wren |> Map.put("home", "nowhere") |> Map.put("knows", ["green", "the-moon"])
        end)

      assert problems(json) == [
               ~s(entities["wren"].home: "nowhere" is not a place of this world),
               ~s(entities["wren"].knows: "the-moon" is not a place of this world)
             ]
    end

    test "a body with no position is allowed: it is nowhere" do
      json = with_entity(tiny(), "wren", &(&1 |> Map.delete("position") |> Map.delete("home")))
      assert %Definition{} = decode!(json)
    end

    test "the terrain names places of the entities, and only those" do
      json =
        tiny()
        |> put_in(["rules", "earthlike.valley", "river", "source", "from"], "hilltop")
        |> put_in(["rules", "earthlike.valley", "river", "through"], ["pond", "brook-head"])
        |> put_in(["rules", "earthlike.valley", "rises", Access.at(0), "place"], "mount-doom")
        |> put_in(["rules", "earthlike.valley", "clay"], [
          %{"place" => "wren", "radius_cells" => 2}
        ])

      assert problems(json) == [
               ~s(rules.earthlike.valley.river.source.from: "hilltop" is not a place of this world),
               ~s(rules.earthlike.valley.river.through[1]: "brook-head" is not a place of this world),
               ~s(rules.earthlike.valley.rises[0]: "mount-doom" is not a place of this world),
               ~s(rules.earthlike.valley.clay[0]: "wren" is not a place of this world)
             ]
    end

    test "a hearth, a standing miracle and the guests' door are at places, the river's source included" do
      json =
        tiny()
        |> put_in(["rules", "earthlike.fire", "hearths", Access.at(0), "at"], "brook-head")
        |> put_in(["miracles", Access.at(1), "at"], "brook-head")
        |> put_in(["guests", "arrival"], "brook-head")

      assert %Definition{} = decode!(json)

      json =
        tiny()
        |> put_in(["rules", "earthlike.fire", "hearths", Access.at(0), "at"], "wren")
        |> put_in(["miracles", Access.at(1), "at"], "the-moon")
        |> put_in(["guests", "arrival"], "wren")

      assert problems(json) == [
               ~s(rules.earthlike.fire.hearths["hearth"].at: "wren" is not a place of this world),
               ~s(miracles["ember"].at: "the-moon" is not a place of this world),
               ~s(guests.arrival: "wren" is not a place of this world)
             ]
    end

    test "an event's target exists and has the component it changes" do
      json =
        tiny()
        |> put_in(["miracles", Access.at(0), "target"], "the-moon")
        |> update_in(
          ["miracles"],
          &(&1 ++ [spring_on("green"), hearth_on("pond"), hearth_on("ember")])
        )

      assert problems(json) == [
               ~s(miracles["brook-fails"].target: "the-moon" is not in this world),
               ~s|miracles["m-green"].target: "green" has no spring (only the river's source has)|,
               ~s(miracles["m-pond"].target: "pond" is not a hearth)
             ]
    end

    test "an event sets the values its component has" do
      json =
        put_in(tiny(), ["miracles", Access.at(0), "set"], %{"flow_m3_s" => 0.0, "fuel_kg" => 1.0})

      assert problems(json) == [
               ~s(miracles["brook-fails"].set: fuel_kg cannot be set on a spring)
             ]
    end

    test "a character is a body, and what its routine names is in the world" do
      json =
        tiny()
        |> update_in(["characters"], &Map.put(&1, "pond", %{"norms" => []}))
        |> put_in(
          ["characters", "wren", "routine", Access.at(0), "do", Access.at(0), "target"],
          "the-moon"
        )

      assert problems(json) == [
               ~s(characters["pond"]: "pond" is not a body of this world),
               ~s(characters["wren"].routine[0].do[0].target: "the-moon" is not in this world)
             ]
    end

    test "a routine may name a hearth, a body, an item and the river's source" do
      steps =
        for target <- ["hearth", "wren", "wren-book", "brook-head", "ember"],
            do: %{"verb" => "go", "target" => target}

      json = put_in(tiny(), ["characters", "wren", "routine", Access.at(0), "do"], steps)
      assert %Definition{} = decode!(json)
    end

    defp spring_on(target), do: event("m-#{target}", target, "spring", %{"flow_m3_s" => 0.0})
    defp hearth_on(target), do: event("m-#{target}", target, "hearth", %{"fuel_kg" => 0.0})

    defp event(id, target, component, set) do
      %{
        "id" => id,
        "kind" => "event",
        "at" => 5,
        "target" => target,
        "component" => component,
        "set" => set
      }
    end
  end

  describe "writing" do
    test "the order of entities in a file is not part of the definition" do
      json = update_in(tiny(), ["entities"], &Enum.reverse/1)
      assert decode!(json) == decode!(tiny())
      assert Definition.hash(decode!(json)) == Definition.hash(decode!(tiny()))
    end

    test "what is encoded reads back as the same definition" do
      definition = decode!(tiny())
      assert {:ok, ^definition} = definition |> Definition.encode() |> Definition.decode()
      assert {:ok, ^definition} = definition |> Definition.to_json() |> Definition.from_json()
    end

    test "the text of a definition is deterministic and begins with what names it" do
      text = tiny() |> decode!() |> Definition.to_json()

      assert text == tiny() |> decode!() |> Definition.to_json()
      assert String.ends_with?(text, "}\n")

      assert String.starts_with?(
               text,
               ~s({\n  "schema": 1,\n  "id": "tiny",\n  "name": "Tiny",\n)
             )
    end

    test "a short object stays on a line, a long one does not" do
      text = tiny() |> decode!() |> Definition.to_json()

      assert text =~ ~s("position": [10, 10])
      assert text =~ ~s("start": {"year": 1, "day": 3, "hour": 6})
      assert text =~ ~s("repr": {"name": "Wren", "description": "A girl."})
      refute text =~ ~r/^.{89,}$/m
    end

    test "a float keeps its point, so it reads back a float" do
      definition = decode!(tiny())
      text = Definition.to_json(definition)

      assert text =~ ~s("power_w": 3000.0)
      assert text =~ ~s("fuel_kg": 5.0)
      assert text =~ ~s("height_m": 4,)
      assert {:ok, ^definition} = Definition.from_json(text)
    end

    test "the hash is over the data, not the text" do
      definition = decode!(tiny())
      hash = Definition.hash(definition)

      assert hash =~ ~r/\A[0-9a-f]{64}\z/

      assert hash ==
               definition
               |> Definition.to_json()
               |> Definition.from_json()
               |> elem(1)
               |> Definition.hash()

      # The same file with its keys in another order and spread over more lines.
      reordered =
        tiny()
        |> Enum.reverse()
        |> Map.new()
        |> JSON.encode!()
        |> String.replace(",", ",\n  ")

      assert {:ok, same} = Definition.from_json(reordered)
      assert Definition.hash(same) == hash
    end

    test "any change to what a world is changes its hash" do
      hash = tiny() |> decode!() |> Definition.hash()

      changes = [
        &put_in(&1, ["seed"], 8),
        &put_in(&1, ["name"], "Tinier"),
        &put_in(&1, ["start"], %{"year" => 1, "day" => 3, "hour" => 7}),
        &put_in(&1, ["rules", "earthlike.weather", "wind", "m_s"], 1.6),
        &put_in(&1, ["rules", "earthlike.fire", "hearths", Access.at(0), "fuel_kg"], 5.5),
        &put_in(&1, ["miracles", Access.at(0), "at"], %{"year" => 1, "day" => 4}),
        &put_in(&1, ["characters", "wren", "routine", Access.at(0), "at"], "07:31"),
        &with_entity(&1, "wren", fn wren -> put_in(wren, ["repr", "name"], "Wrenna") end)
      ]

      for change <- changes do
        assert tiny() |> change.() |> decode!() |> Definition.hash() != hash
      end
    end

    test "who may arrive, and where, is how a world is run: it is not part of the hash" do
      hash = tiny() |> decode!() |> Definition.hash()

      for change <- [
            &put_in(&1, ["guests", "max"], 4),
            &put_in(&1, ["guests", "arrival"], "pond"),
            &Map.delete(&1, "guests")
          ] do
        assert tiny() |> change.() |> decode!() |> Definition.hash() == hash
      end

      # But the file says it, and a definition with other guests is another file.
      refute tiny() |> put_in(["guests", "max"], 4) |> decode!() |> Definition.to_json() ==
               tiny() |> decode!() |> Definition.to_json()
    end

    test "writing refuses what the schema cannot hold" do
      definition = decode!(tiny())
      [{"wren", spec}] = definition.settings[:characters]

      bad =
        put_in_settings(definition, :characters, [{"wren", Keyword.put(spec, :norms, [:tithe])}])

      assert_raise ArgumentError, ~r/:tithe is not one of "invited_fire"/, fn ->
        Definition.encode(bad)
      end

      bad = put_in_settings(definition, :climate, wind: [from: "north", gusts: 3])

      assert_raise ArgumentError, ~r/cannot write the keys \[:gusts\]/, fn ->
        Definition.encode(bad)
      end
    end

    defp put_in_settings(definition, key, value),
      do: %{definition | settings: Keyword.put(definition.settings, key, value)}

    test "a miracle with no kind is written as the event it is" do
      definition = decode!(tiny())
      [event, standing] = definition.settings[:miracles]

      loose = %{
        definition
        | settings:
            Keyword.put(definition.settings, :miracles, [Keyword.delete(event, :kind), standing])
      }

      assert {:ok, ^definition} = loose |> Definition.encode() |> Definition.decode()
    end
  end

  describe "the world it builds" do
    test "is a region with the entities, the settings and the start the file gives" do
      region = tiny() |> decode!() |> Definition.region(id: {0, 0}, systems: [Avwe.Systems.Fire])

      assert %Region{id: {0, 0}, seed: 7, dt: 60, systems: [{"earthlike.fire/step", []}]} = region
      assert region.time == Avwe.Calendar.at(1, day: 3, hour: 6)

      assert Region.get(region, "green", :position) == {10, 10}
      assert Region.get(region, "wren", :knows) == MapSet.new(["green", "pond"])
      assert Region.get(region, "hearth", :hearth).fuel_kg == 5.0
      assert Region.get(region, "brook-head", :spring).flow_m3_s == 1.0
      assert Region.get(region, "ember", :repr).name == "The Ember"
      assert Region.get(region, "wren", :norms) == [:invited_fire]
      assert Region.get(region, "wren-book", :carried_by) == "wren"
      assert region.env.wind == %{from: "north", m_s: 1.5}
      assert region.terrain != nil
    end

    test "a time given in seconds is that time" do
      region = tiny() |> Map.put("start", 3600) |> decode!() |> Definition.region(id: {0, 0})
      assert region.time == 3600
    end

    test "a step is as long as the file says" do
      region = tiny() |> Map.put("dt", 30) |> decode!() |> Definition.region(id: {0, 0})
      assert region.dt == 30
    end

    test "the same definition gives the same region" do
      definition = decode!(tiny())

      assert Region.state_hash(Definition.region(definition, id: {0, 0})) ==
               Region.state_hash(Definition.region(definition, id: {0, 0}))
    end

    test "a world with no terrain has none, and one with an empty valley has a land" do
      bare = %{"schema" => 1, "id" => "b", "name" => "B", "seed" => 1, "start" => 0}
      assert Definition.region(decode!(bare), id: {0, 0}).terrain == nil

      valley = Map.put(bare, "rules", %{"earthlike.valley" => %{}})
      assert %Avwe.Terrain{} = Definition.region(decode!(valley), id: {0, 0}).terrain
    end
  end

  describe "the files that are checked in" do
    for {what, name} <- [
          {"the Ember Reach, from the Quire fixture", :fixture},
          {"the Ember Reach, as it is run", :dev}
        ] do
      test "#{what}, is a valid definition, written the way to_json writes it" do
        path =
          case unquote(name) do
            :fixture -> Fixtures.ember_reach_definition_path()
            :dev -> Application.app_dir(:avwe, "priv/worlds/ember-reach/definition.json")
          end

        text = File.read!(path)
        assert {:ok, definition} = Definitions.load(path)
        assert Definition.to_json(definition) == text
        assert definition.id == "ember-reach"
        assert definition.seed == :erlang.phash2(:ember_reach)
      end
    end

    # What a saved world is known by. If this fails because the recipe or the
    # fixture changed on purpose, change the hash here; if it fails because
    # `hash/1` or the canonical form changed, every world saved under a
    # definition will refuse to start, and that wants a decision, not a fix.
    test "the fixture's definition has the hash that saved worlds carry" do
      assert Definition.hash(Fixtures.ember_reach_definition()) ==
               "8d92690fee8b93e5143481d8be12b5d28d956c317c5726556da02f04a27b7ebb"
    end
  end
end
