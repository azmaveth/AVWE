defmodule Avwe.Definition.ExportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Avwe.{Definition, Definitions, Quire}
  alias Avwe.Definition.Export
  alias Avwe.Quire.{Article, World}
  alias Avwe.Test.Fixtures

  @moduletag :tmp_dir

  defp fixture_world do
    {:ok, world} = Quire.load(Fixtures.ember_reach())
    world
  end

  # A Quire world of the smallest kind: two pinned places, a character at home
  # in one and one with no home.
  defp small_world(extra_articles \\ []) do
    articles =
      [
        %Article{id: "green", title: "The Green", type: :location, summary: "Grass."},
        %Article{id: "pond", title: "The Pond", type: :location, summary: nil},
        %Article{
          id: "wren",
          title: "Wren",
          type: :character,
          summary: "A girl.",
          fields: %{"home" => "The Green", "species" => "Hollow-folk"}
        },
        %Article{id: "moth", title: "Moth", type: :character, summary: "Nobody knows."}
      ] ++ extra_articles

    World.new(
      %{"id" => "small", "name" => "Small", "tagline" => "Two places."},
      %{
        "pins" => [
          %{
            "id" => "green",
            "x" => 10.0,
            "y" => 10.0,
            "label" => "Green",
            "articleId" => "green"
          },
          %{"id" => "pond", "x" => 40.0, "y" => 20.0, "label" => "Pond", "articleId" => "pond"}
        ]
      },
      %{},
      articles
    )
  end

  describe "a definition from Quire and a recipe" do
    test "is the file that is checked in for the Ember Reach, fixture and all" do
      definition = Export.from_quire(fixture_world(), Fixtures.ember_reach_recipe())

      assert Definition.to_json(definition) == File.read!(Fixtures.ember_reach_definition_path())
      assert definition == Fixtures.ember_reach_definition()
    end

    test "has the places and bodies Quire gives, each with its components" do
      definition = Export.from_quire(small_world(), seed: 3)

      assert definition.id == "small"
      assert definition.name == "Small"
      assert definition.tagline == "Two places."
      assert definition.seed == 3
      assert definition.start == 0
      assert definition.dt == 60
      assert Enum.map(definition.entities, &elem(&1, 0)) == ["green", "moth", "pond", "wren"]

      {"green", green} = List.keyfind(definition.entities, "green", 0)

      assert green == %{
               place: %{label: "Green"},
               position: {25, 25},
               repr: %{name: "Green", description: "Grass."},
               article: "green"
             }

      {"wren", wren} = List.keyfind(definition.entities, "wren", 0)
      assert wren.body == %{species: "Hollow-folk"}
      assert wren.home == "green"
      assert wren.position == {25, 25}
      assert wren.knows == MapSet.new(["green", "pond"])
    end

    test "gives a character with no home a body that is nowhere" do
      definition = Export.from_quire(small_world(), seed: 3)
      {"moth", moth} = List.keyfind(definition.entities, "moth", 0)

      assert Map.keys(moth) |> Enum.sort() == [:article, :body, :knows, :repr]
      refute Map.has_key?(moth, :position)
    end

    test "takes the rest from the recipe, character ids and all" do
      recipe = [
        seed: 3,
        start: {2, day: 5},
        dt: 30,
        guests: [arrival: "green", max: 2],
        hearths: [[id: "hearth", at: "green", name: "the hearth", fuel_kg: 1.0, power_w: 100.0]],
        characters: [wren: [norms: [:invited_fire]]]
      ]

      definition = Export.from_quire(small_world(), recipe)

      assert definition.start == {2, day: 5}
      assert definition.dt == 30
      assert definition.guests == [arrival: "green", max: 2]
      assert definition.settings[:characters] == [{"wren", [norms: [:invited_fire]]}]
      assert Keyword.keys(definition.settings) == [:hearths, :characters]
    end

    test "names a standing miracle after the article with its id, else after the recipe, else after its id" do
      standing = fn id, extra ->
        [id: id, kind: :standing, at: "green", heat_w: 100.0, note: "n"] ++ extra
      end

      article = %Article{id: "coal", title: "The Coal", type: :item, summary: "Glows."}

      definition =
        Export.from_quire(small_world([article]),
          seed: 3,
          miracles: [
            standing.("coal", name: "Ignored"),
            standing.("ash", name: "The Ash", description: "Grey."),
            standing.("bare", [])
          ]
        )

      by_id = Map.new(definition.settings[:miracles], &{&1[:id], &1})

      assert {by_id["coal"][:name], by_id["coal"][:description]} == {"The Coal", "Glows."}
      assert {by_id["ash"][:name], by_id["ash"][:description]} == {"The Ash", "Grey."}
      assert {by_id["bare"][:name], by_id["bare"][:description]} == {"bare", nil}
    end

    test "an event miracle is an event, and says so" do
      miracle = [
        id: "m",
        at: {1, day: 2},
        target: "x",
        component: :spring,
        set: %{flow_m3_s: 0.0}
      ]

      definition =
        Export.from_quire(small_world(),
          seed: 3,
          terrain: [river: river()],
          miracles: [Keyword.put(miracle, :target, "brook-head")]
        )

      assert [event] = definition.settings[:miracles]
      assert event[:kind] == :event
    end

    test "a recipe the schema cannot hold is refused with every problem" do
      recipe = [
        seed: 3,
        hearths: [[id: "hearth", at: "green", name: "h", fuel_kg: -1.0, power_w: 0.0]],
        guests: [arrival: "green", max: 0]
      ]

      error = assert_raise ArgumentError, fn -> Export.from_quire(small_world(), recipe) end

      assert error.message ==
               """
               the recipe does not make a valid definition:
                 rules.earthlike.fire.hearths[0].fuel_kg: expected a number, 0 or more, got -1.0
                 rules.earthlike.fire.hearths[0].power_w: expected a number above 0, got 0.0
                 guests.max: expected a whole number above 0, got 0\
               """
    end

    test "a recipe that names what the world has not is refused with every problem" do
      recipe = [
        seed: 3,
        hearths: [[id: "hearth", at: "the-moon", name: "h", fuel_kg: 1.0, power_w: 100.0]],
        guests: [arrival: "nowhere", max: 2]
      ]

      error = assert_raise ArgumentError, fn -> Export.from_quire(small_world(), recipe) end

      assert error.message ==
               """
               the recipe does not make a valid definition:
                 rules.earthlike.fire.hearths["hearth"].at: "the-moon" is not a place of this world
                 guests.arrival: "nowhere" is not a place of this world\
               """
    end

    test "needs a seed" do
      assert_raise KeyError, ~r/key :seed not found/, fn ->
        Export.from_quire(small_world(), [])
      end
    end
  end

  describe "the checked-in definition of the Ember Reach as it is run" do
    test "is made from the same recipe as the fixture's: Quire's words aside, the same world" do
      {:ok, dev} = Definitions.load("ember-reach")
      fixture = Fixtures.ember_reach_definition()

      assert strip(dev) == strip(fixture)
    end

    # What Quire says (names, summaries, where the pins are, the standing
    # miracle's words) is allowed to differ; what the recipe says is not.
    defp strip(definition) do
      miracles =
        for miracle <- definition.settings[:miracles] do
          if miracle[:kind] == :standing,
            do: Keyword.drop(miracle, [:name, :description]),
            else: miracle
        end

      settings = Keyword.put(definition.settings, :miracles, miracles)
      Map.take(%{definition | settings: settings}, [:seed, :start, :dt, :guests, :settings])
    end
  end

  describe "mix avwe.definition.export" do
    alias Mix.Tasks.Avwe.Definition.Export, as: Task

    defp recipe_file(dir, recipe \\ nil) do
      path = Path.join(dir, "source.exs")
      File.write!(path, recipe || File.read!("priv/worlds/ember-reach/source.exs"))
      path
    end

    test "writes the definition of a Quire folder and a recipe, and says what it wrote", %{
      tmp_dir: dir
    } do
      out = Path.join([dir, "made", "definition.json"])

      output =
        capture_io(fn ->
          Task.run([
            "ember-reach",
            "--quire",
            Fixtures.ember_reach(),
            "--source",
            recipe_file(dir),
            "--out",
            out
          ])
        end)

      assert File.read!(out) == File.read!(Fixtures.ember_reach_definition_path())

      assert output =~
               "Wrote #{out}: 5 entities, hash #{Definition.hash(Fixtures.ember_reach_definition())}"
    end

    test "takes the Quire folder from the recipe, under the Quire root, when not told", %{
      tmp_dir: dir
    } do
      recipe = recipe_file(dir, "[seed: 1, quire: \"no-such-world\"]")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Task.run(["x", "--source", recipe, "--out", Path.join(dir, "o.json")])
          end)
        end

      quire_root = Application.fetch_env!(:avwe, :quire_root)
      assert error.message =~ "cannot read Quire world #{Path.join(quire_root, "no-such-world")}"
    end

    test "stops, saying why, when it has nothing to go on", %{tmp_dir: dir} do
      error = assert_raise Mix.Error, fn -> Task.run([]) end
      assert error.message =~ "usage: mix avwe.definition.export NAME"

      error =
        assert_raise Mix.Error, fn -> Task.run(["x", "--source", Path.join(dir, "none.exs")]) end

      assert error.message =~ "no recipe at"

      error =
        assert_raise Mix.Error, fn ->
          Task.run(["x", "--source", recipe_file(dir, "[seed: 1]")])
        end

      assert error.message =~ "no Quire folder: give --quire DIR"

      error =
        assert_raise Mix.Error, fn ->
          Task.run(["x", "--source", recipe_file(dir, ":not_a_list")])
        end

      assert error.message =~ "must give a keyword list"
    end

    test "stops with every problem when the recipe makes a definition that is not valid", %{
      tmp_dir: dir
    } do
      recipe = recipe_file(dir, ~s([seed: 1, guests: [arrival: "nowhere", max: 0]]))
      out = Path.join(dir, "o.json")

      error =
        assert_raise Mix.Error, fn ->
          Task.run(["x", "--quire", Fixtures.ember_reach(), "--source", recipe, "--out", out])
        end

      assert error.message =~ "the recipe does not make a valid definition"
      assert error.message =~ "guests.max: expected a whole number above 0, got 0"
      refute File.exists?(out)
    end
  end

  defp river do
    [
      name: "the Brook",
      flow_m3_s: 1.0,
      water_c: 12.0,
      source: [id: "brook-head", name: "The Head", from: "pond", bearing: 20..70, cells: 10..12],
      through: ["pond"],
      exit: :south
    ]
  end
end
