defmodule Avwe.QuireTest do
  use ExUnit.Case, async: true

  alias Avwe.Quire
  alias Avwe.Quire.{Article, World}
  alias Avwe.Test.Fixtures

  describe "load/1 with the Ember Reach" do
    setup do
      {:ok, world} = Quire.load(Fixtures.ember_reach())
      %{world: world}
    end

    test "reads the world's metadata", %{world: world} do
      assert world.id == "ember-reach"
      assert world.name == "The Ember Reach"
    end

    test "reads every article with its type and fields", %{world: world} do
      assert map_size(world.articles) == 8

      assert %Article{type: :character, title: "Mira Vale", fields: fields, body: body} =
               world.articles["mira-vale"]

      assert fields["occupation"] == "Cartographer"
      assert fields["home"] == "Ember Reach"
      assert body =~ "walks the banks before dawn"

      assert world.articles["the-last-coal"].type == :item
      assert world.articles["kiln-houses"].type == :article
    end

    test "reads the map pins", %{world: world} do
      assert Enum.map(world.pins, & &1.id) ==
               ["ember-reach", "willow-docks", "ashwarden-lodge", "the-dry-bend"]

      assert %World.Pin{label: "The Dry Bend", x: 64.0, y: 30.5} = List.last(world.pins)
    end

    test "reads the canon timeline in order", %{world: world} do
      assert Enum.map(world.timeline, & &1.sort_key) == [780, 804, 812, 813]
      assert hd(world.timeline).title == "Founding of Ember Reach"
    end
  end

  describe "errors" do
    @describetag :tmp_dir

    test "a missing folder is reported", %{tmp_dir: dir} do
      assert {:error, {:read, path, :enoent}} = Quire.load(Path.join(dir, "nowhere"))
      assert path =~ "world.json"
    end

    test "an article without front matter is reported", %{tmp_dir: dir} do
      File.cp_r!(Fixtures.ember_reach(), dir)
      File.write!(Path.join([dir, "articles", "broken.md"]), "No front matter here.")

      assert {:error, {:invalid_article, path, :front_matter}} = Quire.load(dir)
      assert path =~ "broken.md"
    end

    test "an article without a title is reported", %{tmp_dir: dir} do
      File.cp_r!(Fixtures.ember_reach(), dir)
      File.write!(Path.join([dir, "articles", "untitled.md"]), "---\nid: untitled\n---\nBody.")

      assert {:error, {:invalid_article, _path, {:missing, "title"}}} = Quire.load(dir)
    end
  end
end
