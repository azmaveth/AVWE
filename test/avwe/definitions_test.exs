defmodule Avwe.DefinitionsTest do
  # The definitions root is a setting of the application, so one test changes it.
  use ExUnit.Case, async: false

  alias Avwe.{Definition, Definitions}

  @moduletag :tmp_dir

  defp tiny, do: %{"schema" => 1, "id" => "tiny", "name" => "Tiny", "seed" => 7, "start" => 0}

  test "a definition is read from the path of a file", %{tmp_dir: dir} do
    path = Path.join(dir, "tiny.json")
    File.write!(path, JSON.encode!(tiny()))

    assert {:ok, %Definition{id: "tiny", name: "Tiny", seed: 7}} = Definitions.load(path)
  end

  test "the Ember Reach is found by its name" do
    assert {:ok, %Definition{id: "ember-reach", name: "The Ember Reach"}} =
             Definitions.load("ember-reach")
  end

  test "a name is a folder of the definitions root, which is a setting", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "tiny"))
    File.write!(Path.join([dir, "tiny", "definition.json"]), JSON.encode!(tiny()))

    root = Application.get_env(:avwe, :definitions_root)
    Application.put_env(:avwe, :definitions_root, dir)

    on_exit(fn ->
      if root,
        do: Application.put_env(:avwe, :definitions_root, root),
        else: Application.delete_env(:avwe, :definitions_root)
    end)

    assert {:ok, %Definition{id: "tiny"}} = Definitions.load("tiny")
    assert {:error, {:read_definition, path, :enoent}} = Definitions.load("ember-reach")
    assert path == Path.join([dir, "ember-reach", "definition.json"])
  end

  test "a file that is not there, and a name that is not a name, are told apart", %{tmp_dir: dir} do
    missing = Path.join(dir, "missing.json")
    assert {:error, {:read_definition, ^missing, :enoent}} = Definitions.load(missing)

    for name <- ["../secrets", "Ember-Reach", "ember reach", "", "a/b", "-x"] do
      assert {:error, {:bad_definition_name, ^name}} = Definitions.load(name)
    end

    # A name that is a name but names nothing is a file that is not there.
    assert {:error, {:read_definition, path, :enoent}} = Definitions.load("no-such-world")
    assert String.ends_with?(path, "priv/worlds/no-such-world/definition.json")
  end

  test "a definition that is wrong is refused with the path, and every problem at once", %{
    tmp_dir: dir
  } do
    json = tiny() |> Map.put("schema", 2) |> Map.put("seed", "seven") |> Map.delete("name")
    path = Path.join(dir, "wrong.json")
    File.write!(path, JSON.encode!(json))

    assert {:error, {:invalid_definition, ^path, problems}} = Definitions.load(path)

    assert problems == [
             "schema: expected the schema version 1, got 2",
             "name: missing",
             ~s(seed: expected a whole number, got "seven")
           ]

    assert Definition.explain({:invalid_definition, path, problems}) ==
             """
             #{path} is not a valid world definition:
               schema: expected the schema version 1, got 2
               name: missing
               seed: expected a whole number, got "seven"\
             """
  end

  test "a file that is not JSON is refused in a sentence", %{tmp_dir: dir} do
    path = Path.join(dir, "text.json")
    File.write!(path, "this is not JSON")

    assert {:error, {:invalid_definition, ^path, [problem]}} = Definitions.load(path)
    assert problem =~ "the file is not JSON"
  end
end
