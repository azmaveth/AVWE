defmodule Avwe.E2E.DefinitionTest do
  @moduledoc """
  End to end: a world run from its definition file (`Avwe.Definition`), as the
  Ember Reach runs now, and not from Quire and settings. A telnet player and an
  MCP player find the same world either way, word for word; the definition is
  recorded in what the world saves, and a saved world is resumed under it and
  no other; and a file that is wrong, or a start that mixes sources, is refused
  in plain words.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.MCPClient, only: [call: 2, call: 3, connect: 1, close: 1]
  import Avwe.Test.TelnetClient, only: [send_line: 2, expect: 2]
  import ExUnit.CaptureLog

  alias Avwe.{Definition, Definitions, Region, RegionServer, Session, Store}
  alias Avwe.Test.{HTTPClient, TelnetClient}

  @moduletag :tmp_dir
  @world :ember_defined
  @region {0, 0}
  @ref :ember_defined_mcp

  setup do
    on_exit(fn -> Avwe.stop_world(@world) end)
    :ok
  end

  defp definition_opts(overrides \\ []),
    do: Keyword.merge([definition: ember_reach_definition_path()], overrides)

  defp live_hash do
    {:ok, hash} = RegionServer.state_hash(@world, @region)
    hash
  end

  defp store_dir(tmp_dir), do: Path.join(tmp_dir, to_string(@world))

  defp saved(tmp_dir) do
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    result = {Store.rebuild_with_definition(store), Store.rebuild_from_start(store)}
    :ok = Store.close(store)
    result
  end

  defp stop_quietly(client) do
    close(client)
  catch
    :exit, _gone -> :ok
  end

  describe "a player in a world run from its definition" do
    # What a telnet player is told, line for line, as they play Mira for a
    # morning: the greeting, the look, the walk, her words, her notebook.
    defp telnet_transcript(world_opts) do
      {:ok, _pid} = Avwe.start_world(@world, world_opts)
      id = make_ref()

      port =
        Avwe.Telnet.port(start_supervised!(Supervisor.child_spec({Avwe.Telnet, port: 0}, id: id)))

      socket = TelnetClient.connect(port)
      greeting = expect(socket, "watch without a body")
      send_line(socket, "mira")
      joined = expect(socket, ~r/^You know the way to/)

      script = [
        "look",
        "kindle",
        {:step, 5},
        "go dry bend",
        {:step, 12},
        "look",
        "say Is the water gone?",
        "write The bend is dry; the hearth is lit.",
        "read",
        {:step, 1},
        "time"
      ]

      body =
        Enum.flat_map(script, fn
          {:step, n} ->
            Avwe.step(@world, n)
            []

          command ->
            send_line(socket, command)
            send_line(socket, "time")
            expect(socket, ~r/^\d+ AR, day \d+, \d\d:\d\d$/)
        end)

      send_line(socket, "quit")
      :gen_tcp.close(socket)
      stop_supervised!(id)
      :ok = Avwe.stop_world(@world)

      greeting ++ joined ++ body
    end

    test "is told what a player of the world made from Quire and settings is told, word for word" do
      from_quire = telnet_transcript(ember_reach_opts())
      from_definition = telnet_transcript(definition_opts())

      assert from_definition == from_quire

      assert Enum.any?(
               from_definition,
               &(&1 =~ "You are in The Ember Reach. A river valley remembering")
             )

      assert Enum.any?(
               from_definition,
               &(&1 =~ "Mira Vale leaves, heading toward The Dry Bend" or
                   &1 =~ "You arrive at The Dry Bend")
             )

      assert Enum.any?(from_definition, &(&1 =~ ~s(You say, "Is the water gone?")))
    end

    test "is also told it by an agent over MCP" do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts())
      start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
      client = connect(Avwe.MCP.port(@ref))
      on_exit(fn -> stop_quietly(client) end)

      bodies = call(client, "bodies")
      assert bodies.text =~ "- Mira Vale (id: mira-vale)"

      refute call(client, "join", %{"body" => "mira"}).error?
      look = call(client, "look")
      assert look.text =~ "You are Mira Vale, at Ember Reach."
      assert look.text =~ "A river town of kiln-houses and willow docks"

      %{error?: false} = call(client, "act", %{"verb" => "kindle"})
      Avwe.step(@world, 3)
      assert call(client, "look").text =~ "hearth"
    end

    test "is offered by the web client's lobby, under the name its definition gives" do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts())
      {:ok, {_ip, port}} = AvweWeb.Endpoint.server_info(:http)

      response = HTTPClient.request(port, "GET", "/")

      assert response.status == 200
      assert response.body =~ "The Ember Reach"
      assert response.body =~ "A river valley remembering its last summer."
      assert response.body =~ ~s(href="/play/ember_defined/mira-vale")
    end

    test "is in a world that says which definition it came from" do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts())
      {:ok, _pid} = Avwe.start_world(:ember_from_quire, ember_reach_opts())
      on_exit(fn -> Avwe.stop_world(:ember_from_quire) end)

      worlds = Map.new(Avwe.worlds())
      hash = Definition.hash(ember_reach_definition())

      assert worlds[@world].definition == hash
      assert worlds[@world].name == "The Ember Reach"
      assert worlds[@world].tagline == "A river valley remembering its last summer."
      assert worlds[@world].guests == %{arrival: "ember-reach", max: 8}
      assert worlds[:ember_from_quire].definition == nil
    end

    test "arrives by name, as the configuration of the world gives it, without reading Quire" do
      quire_root = Application.get_env(:avwe, :quire_root)
      Application.put_env(:avwe, :quire_root, "/nonexistent/quire")
      on_exit(fn -> Application.put_env(:avwe, :quire_root, quire_root) end)

      log =
        capture_log(fn ->
          assert {:ok, _pid} = Avwe.start_world(:ember_reach)
        end)

      on_exit(fn -> Avwe.stop_world(:ember_reach) end)

      assert {:ok, definition} = Definitions.load("ember-reach")
      assert Map.new(Avwe.worlds())[:ember_reach].definition == Definition.hash(definition)

      # Whoever is placed in the definition can be played, and whoever is not
      # cannot: what canon says today is not what this test is about.
      {nowhere, somewhere} =
        for({_id, %{body: _body}} = body <- definition.entities, do: body)
        |> Enum.split_with(fn {_id, components} -> not is_map_key(components, :position) end)

      {:ok, playable} = Avwe.bodies(:ember_reach)
      {:ok, away} = Avwe.elsewhere(:ember_reach)

      assert "mira-vale" in Enum.map(playable, & &1.id)
      assert Enum.map(playable, & &1.id) == Enum.map(somewhere, &elem(&1, 0))
      assert Enum.map(away, & &1.id) == Enum.map(nowhere, &elem(&1, 0))

      names = for {_id, %{repr: %{name: name}}} <- nowhere, do: name

      if names == [],
        do: refute(log =~ "not placed"),
        else: assert(log =~ "so nobody can play them yet: #{Enum.join(names, ", ")}.")
    end

    test "says which of its bodies are nowhere when it starts" do
      # A body with no position is one nobody can play (Avwe.Quire.Seed), here
      # added to the fixture's definition: two of them, one with no name.
      nowhere = %{body: %{species: nil}, knows: MapSet.new()}

      definition = ember_reach_definition()

      definition = %{
        definition
        | entities:
            Enum.sort(
              definition.entities ++
                [
                  {"brine", Map.put(nowhere, :repr, %{name: "Brine", description: nil})},
                  {"moth", nowhere}
                ]
            )
      }

      log =
        capture_log(fn ->
          assert {:ok, _pid} = Avwe.start_world(@world, definition: definition)
        end)

      assert log =~
               "ember_defined: 2 characters are not placed, so nobody can play them yet: " <>
                 "Brine, moth. A character is placed when its entity has a position."

      assert {:ok, [%{id: "mira-vale"}]} = Avwe.bodies(@world)

      assert {:ok, [%{id: "brine", name: "Brine"}, %{id: "moth", name: "moth"}]} =
               Avwe.elsewhere(@world)
    end

    test "says it of one body in the singular" do
      definition = ember_reach_definition()

      lost =
        {"lost",
         %{body: %{species: nil}, repr: %{name: "Lost", description: nil}, knows: MapSet.new()}}

      log =
        capture_log(fn ->
          assert {:ok, _pid} =
                   Avwe.start_world(@world,
                     definition: %{definition | entities: definition.entities ++ [lost]}
                   )
        end)

      assert log =~ "ember_defined: 1 character is not placed, so nobody can play them yet: Lost."
    end
  end

  describe "a world saved from a definition" do
    defp play(world \\ @world) do
      {:ok, mira} = Avwe.connect(world, body: "mira-vale")
      {:ok, _} = Session.act(mira, :kindle)
      Avwe.step(world, 3)
      {:ok, _} = Session.act(mira, :go, target: "the-dry-bend")
      Avwe.step(world, 40)
      mira
    end

    test "carries the definition in its snapshots, and replays exactly from the log", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _pid} =
        Avwe.start_world(@world, definition_opts(data_dir: tmp_dir, snapshot_every: 20))

      _mira = play()
      hash = live_hash()
      :ok = Avwe.stop_world(@world)

      {{:ok, rebuilt, definition}, {:ok, from_start}} = saved(tmp_dir)

      assert definition == Definition.hash(ember_reach_definition())
      assert Region.state_hash(rebuilt) == hash
      assert Region.state_hash(from_start) == hash
    end

    test "resumes under the same definition, even laid out another way", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      mira = play()
      # Closing her session queues her release, journaled with the rest.
      :ok = Session.close(mira)
      hash = live_hash()
      :ok = Avwe.stop_world(@world)

      # The same data in a file written differently: not another definition.
      relaid = Path.join(tmp_dir, "relaid.json")

      File.write!(
        relaid,
        ember_reach_definition_path()
        |> File.read!()
        |> JSON.decode!()
        |> Enum.reverse()
        |> Map.new()
        |> JSON.encode!()
      )

      log =
        capture_log(fn ->
          assert {:ok, _pid} = Avwe.start_world(@world, definition: relaid, data_dir: tmp_dir)
        end)

      assert live_hash() == hash
      refute log =~ "ignoring"
      refute log =~ "[error]"
    end

    test "takes the guests it is started to take, as a world always has", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      mira = play()
      :ok = Session.close(mira)
      :ok = Avwe.stop_world(@world)

      # More guests, in another place: the same world, so it resumes.
      guests = [arrival: "willow-docks", max: 12]
      other = ember_reach_definition(guests: guests)
      assert Definition.hash(other) == Definition.hash(ember_reach_definition())

      assert {:ok, _pid} = Avwe.start_world(@world, definition: other, data_dir: tmp_dir)
      assert Map.new(Avwe.worlds())[@world].guests == %{arrival: "willow-docks", max: 12}
      assert {:ok, %{step: 43}} = Avwe.snapshot(@world)
    end

    test "refuses to resume under another definition, and says so", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      _mira = play()
      :ok = Avwe.stop_world(@world)
      saved_hash = Definition.hash(ember_reach_definition())

      other = ember_reach_definition(miracles: [])
      other_hash = Definition.hash(other)
      refute other_hash == saved_hash

      log =
        capture_log(fn ->
          assert {:error,
                  {:shutdown,
                   {:failed_to_start_child, _child,
                    {:store, {:definition_changed, ^saved_hash, ^other_hash}}}}} =
                   Avwe.start_world(@world, definition: other, data_dir: tmp_dir)
        end)

      assert log =~ "the world was saved under the definition #{String.slice(saved_hash, 0, 12)}"
      assert log =~ "but is now given under the definition #{String.slice(other_hash, 0, 12)}"
      assert log =~ "delete the world folder #{store_dir(tmp_dir)} to start over"
      assert Avwe.World.whereis(@world) == nil

      # Nothing was written over what was saved.
      assert {{:ok, _rebuilt, ^saved_hash}, _from_start} = saved(tmp_dir)

      # And it still starts under its own.
      assert {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
    end

    test "is not resumed by a world made from Quire, nor the other way round", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      _mira = play()
      :ok = Avwe.stop_world(@world)
      hash = Definition.hash(ember_reach_definition())

      capture_log(fn ->
        assert {:error,
                {:shutdown,
                 {:failed_to_start_child, _child, {:store, {:definition_changed, ^hash, nil}}}}} =
                 Avwe.start_world(@world, ember_reach_opts(data_dir: tmp_dir))
      end)

      File.rm_rf!(store_dir(tmp_dir))
      {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(data_dir: tmp_dir))
      _mira = play()
      :ok = Avwe.stop_world(@world)

      log =
        capture_log(fn ->
          assert {:error,
                  {:shutdown,
                   {:failed_to_start_child, _child, {:store, {:definition_changed, nil, ^hash}}}}} =
                   Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
        end)

      assert log =~ "the world was saved without a definition (from Quire and settings)"
    end

    test "keeps its definition when the rules it runs under change on restart", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      Avwe.step(@world, 5)
      :ok = Avwe.stop_world(@world)

      # The systems are code, not state: the world resumes under the new ones
      # and snapshots at once, so the log from here belongs to them.
      systems = [Avwe.Systems.Daylight, Avwe.Systems.Miracles]
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir, systems: systems))
      Avwe.step(@world, 5)
      :ok = Avwe.stop_world(@world)

      {:ok, store} = Store.open(store_dir(tmp_dir), @region)
      assert Store.snapshots(store) == [0, 5]
      assert {:ok, rebuilt, definition} = Store.rebuild_with_definition(store)
      :ok = Store.close(store)

      assert rebuilt.systems == systems
      assert rebuilt.step == 10
      assert definition == Definition.hash(ember_reach_definition())
    end

    test "gives the same world after a crash of its region as before", %{tmp_dir: tmp_dir} do
      {:ok, _pid} = Avwe.start_world(@world, definition_opts(data_dir: tmp_dir))
      _mira = play()
      hash = live_hash()

      [{region, _table}] = Registry.lookup(Avwe.Registry, {:region, @world, @region})
      Process.exit(region, :kill)

      eventually(
        fn ->
          match?(
            [{pid, _table}] when pid != region,
            Registry.lookup(Avwe.Registry, {:region, @world, @region})
          )
        end,
        10_000
      )

      assert live_hash() == hash
    end
  end

  describe "a start that cannot be made" do
    test "is told, in words, what is wrong with the file, all of it", %{tmp_dir: tmp_dir} do
      broken = Path.join(tmp_dir, "broken.json")

      json =
        ember_reach_definition_path()
        |> File.read!()
        |> JSON.decode!()
        |> Map.put("seed", "seven")
        |> put_in(["guests", "max"], 0)
        |> Map.put("colour", "red")

      File.write!(broken, JSON.encode!(json))

      assert {:error, {:invalid_definition, ^broken, problems}} =
               Avwe.start_world(@world, definition: broken)

      assert length(problems) == 3
      assert ~s(seed: expected a whole number, got "seven") in problems
      assert "guests.max: expected a whole number above 0, got 0" in problems
      assert Enum.any?(problems, &(&1 =~ "colour: not a key of this"))
      assert Avwe.World.whereis(@world) == nil
    end

    test "is told when the file is not there" do
      path = "/nonexistent/definition.json"

      assert {:error, {:read_definition, ^path, :enoent}} =
               Avwe.start_world(@world, definition: path)
    end

    test "is told when both a definition and Quire are given, and when neither is" do
      assert {:error, :definition_and_quire} =
               Avwe.start_world(@world, definition_opts(quire: ember_reach()))

      assert {:error, :no_world_source} = Avwe.start_world(@world, [])
    end

    test "is told which settings cannot be given beside a definition" do
      assert {:error, {:settings_with_definition, [:start, :seed, :miracles]}} =
               Avwe.start_world(
                 @world,
                 definition_opts(miracles: [], seed: 1, start: {1, hour: 1}, clock: :manual)
               )

      assert Avwe.World.whereis(@world) == nil
    end

    test "can be given a definition already read, with the options for running it" do
      assert {:ok, _pid} =
               Avwe.start_world(@world,
                 definition: ember_reach_definition(start: {812, day: 190}),
                 clock: :manual
               )

      assert Avwe.now(@world) == "812 AR, day 190, 00:00"
    end
  end
end
