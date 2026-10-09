defmodule Avwe.ApplicationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup do
    autostart = Application.get_env(:avwe, :autostart)

    on_exit(fn ->
      if autostart,
        do: Application.put_env(:avwe, :autostart, autostart),
        else: Application.delete_env(:avwe, :autostart)

      Avwe.stop_world(:autostarted)
    end)
  end

  test "a world that cannot start from its definition is reported in words, a problem to a line",
       %{tmp_dir: dir} do
    path = Path.join(dir, "broken.json")

    File.write!(
      path,
      ~s({"schema": 1, "id": "b", "name": "B", "seed": "x", "start": 0, "colour": 1})
    )

    Application.put_env(:avwe, :autostart, autostarted: [definition: path])

    log = capture_log(fn -> assert :ok = Avwe.Application.autostart() end)

    assert log =~ "Couldn't start world :autostarted: #{path} is not a valid world definition:\n"
    assert log =~ ~s(\n  seed: expected a whole number, got "x")
    assert log =~ "\n  colour: not a key of this"
    assert Avwe.World.whereis(:autostarted) == nil
  end

  test "a world that is not there to read is reported too" do
    Application.put_env(:avwe, :autostart, autostarted: [definition: "/nonexistent/x.json"])

    log = capture_log(fn -> Avwe.Application.autostart() end)

    assert log =~
             "Couldn't start world :autostarted: cannot read the definition /nonexistent/x.json"
  end

  test "a world that can start does" do
    Application.put_env(:avwe, :autostart, autostarted: [definition: "ember-reach"])

    log = capture_log(fn -> assert :ok = Avwe.Application.autostart() end)

    refute log =~ "Couldn't start"
    assert Avwe.World.whereis(:autostarted) != nil
  end
end
