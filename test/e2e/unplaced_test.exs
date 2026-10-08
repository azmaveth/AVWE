defmodule Avwe.E2E.UnplacedTest do
  @moduledoc """
  End to end: a world with characters that are nowhere, because their homes are
  not pins on the map (Brine's home, the Salt Road, is an article and not a pin;
  Moth has no home). Lantern Hollow with those two wanderers, at noon on a manual
  clock. Every way into the world tells a player who asks for one why they
  cannot be played, and the world carries on around them.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Avwe.Test.Fixtures, only: [hollow_with_wanderers: 1, lantern_hollow: 0]

  alias Avwe.Test.{MCPClient, TelnetClient}

  @world :hollow_wanderers
  @ref :hollow_wanderers_server
  @playable ["odo", "pell", "tamsin", "wren"]
  @brine "Brine lives somewhere the map does not show, so nobody can play them yet."

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # The world says at its start who is not placed (tested below); here it
    # would only put that in the output.
    capture_log(fn ->
      {:ok, _pid} =
        Avwe.start_world(@world, quire: hollow_with_wanderers(dir), start: {1, hour: 12})
    end)

    on_exit(fn -> Avwe.stop_world(@world) end)

    start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
    telnet = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    %{mcp: Avwe.MCP.port(@ref), telnet: telnet}
  end

  describe "the world" do
    test "lists the bodies that can be played, and says who lives off the map" do
      {:ok, bodies} = Avwe.bodies(@world)
      assert Enum.map(bodies, & &1.id) == @playable

      assert {:ok, away} = Avwe.elsewhere(@world)

      assert Enum.map(away, &Map.take(&1, [:id, :name, :description])) == [
               %{id: "brine", name: "Brine", description: "A tinker on the Salt Road."},
               %{id: "moth", name: "Moth", description: "Nobody knows where Moth sleeps."}
             ]
    end

    test "refuses a controller that asks for one, holds nothing, and carries on" do
      assert {:error, :elsewhere} = Avwe.connect(@world, body: "brine", controller: :arbor)
      assert {:error, :elsewhere} = Avwe.connect(@world, body: "moth", controller: :human)
      assert Registry.lookup(Avwe.Registry, {:lease, @world, "brine"}) == []
      assert Registry.lookup(Avwe.Registry, {:lease, @world, "moth"}) == []

      # Two days and nights go by with them nowhere, and the world is well.
      Avwe.step(@world, 2 * 24 * 60)
      {:ok, snapshot} = Avwe.snapshot(@world)
      refute Map.has_key?(snapshot.components.position, "brine")
      refute Map.has_key?(snapshot.components.position, "moth")

      assert {:ok, wren} = Avwe.connect(@world, body: "wren", controller: :arbor)
      assert {:ok, %{body: %{name: "Wren"}}} = Avwe.Session.look(wren)
    end

    test "still refuses a body that does not exist, as before" do
      assert {:error, :no_such_body} = Avwe.connect(@world, body: "ghost")
    end

    test "gives a spectator a scene without them" do
      {:ok, watcher} = Avwe.connect(@world, scenes: true)
      assert {:ok, %Avwe.WorldScene{things: things}} = Avwe.Session.scene(watcher)
      assert for(%{kind: :body, id: id} <- things, do: id) == @playable
    end
  end

  describe "the log" do
    test "says which characters are not placed when the world starts", %{tmp_dir: dir} do
      log =
        capture_log(fn ->
          {:ok, _pid} = Avwe.start_world(:hollow_wanderers_log, quire: dir, start: {1, hour: 12})
        end)

      on_exit(fn -> Avwe.stop_world(:hollow_wanderers_log) end)

      assert log =~ "hollow_wanderers_log: 2 characters are not placed"
      assert log =~ "nobody can play them yet: Brine (home: The Salt Road), Moth (no home)."
      assert log =~ "A character is placed at its home when the home is a pin on the map."
    end

    test "says it in the singular for one", %{tmp_dir: dir} do
      File.rm!(Path.join([dir, "articles", "moth.md"]))

      log =
        capture_log(fn ->
          {:ok, _pid} = Avwe.start_world(:hollow_one_wanderer, quire: dir, start: {1, hour: 12})
        end)

      on_exit(fn -> Avwe.stop_world(:hollow_one_wanderer) end)

      assert log =~ "hollow_one_wanderer: 1 character is not placed"
      assert log =~ "nobody can play them yet: Brine (home: The Salt Road)."
    end

    test "says nothing when every character is placed" do
      log =
        capture_log(fn ->
          {:ok, _pid} = Avwe.start_world(:hollow_all_placed, quire: lantern_hollow(), start: 0)
        end)

      on_exit(fn -> Avwe.stop_world(:hollow_all_placed) end)

      refute log =~ "not placed"
    end
  end

  describe "telnet" do
    test "leaves them out of the menu, and says why when one is asked for", %{telnet: port} do
      socket = TelnetClient.connect(port)
      menu = TelnetClient.expect(socket, "watch without a body")
      assert Enum.any?(menu, &(&1 =~ "  Wren"))
      refute Enum.any?(menu, &(&1 =~ "Brine" or &1 =~ "Moth"))

      TelnetClient.send_line(socket, "brine")
      TelnetClient.expect(socket, @brine <> " Choose someone else, or watch.")

      TelnetClient.send_line(socket, "moth")
      TelnetClient.expect(socket, "Moth lives somewhere the map does not show")

      # Nothing broke: the player can still choose.
      TelnetClient.send_line(socket, "wren")
      TelnetClient.expect(socket, "You are Wren.")
      TelnetClient.expect(socket, ~r/^You are Wren, at Hollow Green/)
    end

    test "still says nobody is there for a name no one has", %{telnet: port} do
      socket = TelnetClient.connect(port)
      TelnetClient.expect(socket, "watch without a body")

      TelnetClient.send_line(socket, "ghost")
      TelnetClient.expect(socket, ~s(There's nobody called "ghost" here.))
    end
  end

  describe "MCP" do
    test "leaves them out of bodies, and join says why", %{mcp: port} do
      client = MCPClient.connect(port, :legacy_only)
      on_exit(fn -> stop_quietly(client) end)

      bodies = MCPClient.call(client, "bodies")
      refute bodies.error?
      refute bodies.text =~ "Brine"
      refute bodies.text =~ "Moth"
      assert bodies.text =~ "- Wren (id: wren): free"
      assert Enum.map(bodies.data["bodies"], & &1["id"]) == @playable

      by_name = MCPClient.call(client, "join", %{"body" => "Brine"})
      assert by_name.error?
      assert by_name.text == @brine

      by_id = MCPClient.call(client, "join", %{"body" => "moth"})
      assert by_id.error?
      assert by_id.text =~ "Moth lives somewhere the map does not show"

      # Nothing was taken: the player can join someone else.
      joined = MCPClient.call(client, "join", %{"body" => "wren"})
      refute joined.error?
      assert joined.text =~ "You are Wren, at Hollow Green."
    end

    test "still says there is no body for a name no one has", %{mcp: port} do
      client = MCPClient.connect(port, :legacy_only)
      on_exit(fn -> stop_quietly(client) end)

      ghost = MCPClient.call(client, "join", %{"body" => "ghost"})
      assert ghost.error? and ghost.text =~ ~s(There is no body called "ghost")
    end
  end

  defp stop_quietly(client) do
    MCPClient.close(client)
  catch
    :exit, _gone -> :ok
  end
end
