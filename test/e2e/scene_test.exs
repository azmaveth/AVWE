defmodule Avwe.E2E.SceneTest do
  @moduledoc """
  End to end through `Avwe.Session`, as a client that draws uses it: Lantern
  Hollow at noon on a manual clock, with a little land (clay around Hollow
  Green), and sessions opened with `scenes: true`. Wren and Tamsin are on
  Hollow Green, Pell at the Mill Pond a few cells east, and Odo in the Far
  Tower 150 cells east, out of sight until he walks.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures

  alias Avwe.{GroundCache, Percept, Scene, Session, Space, WorldScene}
  alias Avwe.Test.Idle

  @world :hollow_scenes
  @terrain [clay: [{"hollow-green", radius_cells: 3}]]

  setup do
    start_hollow(@world, terrain: @terrain)
    on_exit(fn -> Avwe.stop_world(@world) end)

    # The ground map is built once for a terrain, here, so that no test waits
    # for it unless it means to.
    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.fetch(terrain)
    :ok
  end

  defp start_hollow(world, opts \\ []) do
    {:ok, _pid} =
      Avwe.start_world(world, [quire: lantern_hollow(), start: {1, hour: 12}] ++ opts)

    :ok
  end

  defp join(body, opts \\ []) do
    {:ok, session} = Avwe.connect(@world, [body: body, controller: :arbor, scenes: true] ++ opts)
    session
  end

  # A session that asks for nothing, to make things happen.
  defp plain(body) do
    {:ok, session} = Avwe.connect(@world, body: body, controller: :arbor)
    session
  end

  defp first_scene(session) do
    {:ok, scene} = Session.scene(session)
    scene
  end

  # The scenes the session has sent so far, oldest first. Calls the session
  # first, so it has handled every step sent before this call.
  defp scenes(session) do
    _body = Session.body(session)
    drain(session)
  end

  defp drain(session) do
    receive do
      {:avwe_scene, ^session, scene} -> [scene | drain(session)]
    after
      0 -> []
    end
  end

  # What the session has sent the calling process, in the order it arrived.
  defp inbox(session) do
    _body = Session.body(session)
    {:messages, messages} = Process.info(self(), :messages)

    Enum.filter(messages, fn
      {:avwe_scene, ^session, _scene} -> true
      {:avwe_percepts, ^session, _percepts} -> true
      _other -> false
    end)
  end

  # Steps the world once, and returns the scenes the session was sent for it.
  defp step_scenes(session) do
    Avwe.step(@world, 1)
    scenes(session)
  end

  # Steps the world until the session is sent a scene, and returns the number
  # of steps it took and the scene.
  defp step_until_scene(session, limit \\ 30, taken \\ 1)

  defp step_until_scene(_session, limit, taken) when taken > limit,
    do: flunk("no scene after #{limit} steps")

  defp step_until_scene(session, limit, taken) do
    case step_scenes(session) do
      [] -> step_until_scene(session, limit, taken + 1)
      scenes -> {taken, List.last(scenes)}
    end
  end

  defp thing(scene, id), do: Enum.find(scene.things, &(&1.id == id))

  describe "who is sent scenes" do
    test "a session that did not ask for them is sent none, and has none to ask for" do
      odo = plain("odo")
      assert {:ok, nil} = Session.scene(odo)

      {:ok, _ref} = Session.act(odo, :go, target: "hollow-green")
      Avwe.step(@world, 3)

      assert [%Percept{summary: "You set off toward Hollow Green."} | _] = percepts(odo)
      assert scenes(odo) == []
    end

    # A spectator that asks is given the other lens, the whole valley's
    # (`test/e2e/watch_test.exs` has more of it); one that does not ask, as
    # telnet's and MCP's watchers do not, has none, as it always had.
    test "a spectator is given the world's scene if it asks, and none if it does not" do
      watcher = join(nil)
      assert {:ok, %WorldScene{}} = Session.scene(watcher)

      {:ok, quiet} = Avwe.connect(@world)
      assert {:ok, nil} = Session.scene(quiet)

      odo = plain("odo")
      {:ok, _ref} = Session.act(odo, :go, target: "hollow-green")
      Avwe.step(@world, 3)

      assert [%WorldScene{} | _] = scenes(watcher)
      assert scenes(quiet) == []
    end
  end

  describe "who is woken" do
    test "only a session that draws is woken by a step with nothing in it" do
      odo = plain("odo")
      {:ok, quiet} = Avwe.connect(@world)
      watcher = join(nil)
      wren = join("wren")

      # The first steps have events: the sessions take their bodies, and the
      # routines of the others set about waiting.
      Avwe.step(@world, 2)

      sessions = [odo, quiet, watcher, wren]
      for session <- sessions, do: :erlang.trace(session, true, [:receive])
      Avwe.step(@world, 3)
      for session <- sessions, do: Session.body(session)

      {:messages, messages} = Process.info(self(), :messages)

      heard = fn session ->
        Enum.count(messages, &match?({:trace, ^session, :receive, {:avwe_events, _, [], _}}, &1))
      end

      assert {heard.(odo), heard.(quiet), heard.(watcher), heard.(wren)} == {0, 0, 3, 3}
    end
  end

  describe "the first scene" do
    test "shows the viewer, who is in sight, and the ground around them" do
      wren = join("wren")
      scene = first_scene(wren)
      {:ok, look} = Session.look(wren)

      assert %Scene{you: %{id: "wren", name: "Wren"}, radius: 50.0, light: 1.0} = scene
      assert scene.center == look.cell

      by_kind = Enum.group_by(scene.things, & &1.kind, & &1.id)
      assert Enum.sort(by_kind.body) == ["pell", "tamsin"]
      assert Enum.sort(by_kind.place) == ["hollow-green", "mill-pond"]

      # The tower and Odo, 150 cells away, are not in sight.
      refute thing(scene, "far-tower")
      refute thing(scene, "odo")

      assert is_list(scene.rows)
      assert Scene.kind_at(scene, scene.center) == :clay
      assert Map.has_key?(scene.legend, :clay)
    end

    test "has things and no ground in a world with none, and scenes follow all the same" do
      flat = :hollow_flat
      start_hollow(flat)
      on_exit(fn -> Avwe.stop_world(flat) end)

      {:ok, wren} = Avwe.connect(flat, body: "wren", scenes: true)
      {:ok, scene} = Session.scene(wren)
      assert scene.rows == nil
      assert Enum.sort(for t <- scene.things, t.kind == :body, do: t.id) == ["pell", "tamsin"]

      {:ok, tamsin} = Avwe.connect(flat, body: "tamsin")
      {:ok, _ref} = Session.act(tamsin, :go, target: "mill-pond")
      Avwe.step(flat, 3)
      _ = Session.body(wren)

      assert_received {:avwe_scene, ^wren, %Scene{rows: nil} = moved}
      refute thing(moved, "tamsin").cell == thing(scene, "tamsin").cell
    end

    test "is drawn at once, and the ground follows when it has been built" do
      cold = :hollow_cold
      start_hollow(cold, terrain: @terrain, seed: System.unique_integer([:positive]))
      on_exit(fn -> Avwe.stop_world(cold) end)

      {:ok, %{terrain: terrain}} = Avwe.snapshot(cold)
      refute GroundCache.cached?(terrain)

      {:ok, wren} = Avwe.connect(cold, body: "wren", scenes: true)
      {:ok, first} = Session.scene(wren)
      assert first.things != []

      # Building the map takes about a second. Whether or not it had finished by
      # the time of the first scene, the client ends up with the scene that has
      # the ground in it.
      grounded =
        if first.rows do
          first
        else
          assert_receive {:avwe_scene, ^wren, %Scene{rows: [_ | _]} = scene}, 10_000
          scene
        end

      assert Scene.kind_at(grounded, grounded.center) == :clay
      assert GroundCache.cached?(terrain)
    end
  end

  describe "the scenes that follow" do
    test "none is sent before the first is asked for, and that one is the current scene" do
      wren = join("wren")
      pell = plain("pell")
      {:ok, _ref} = Session.act(pell, :go, target: "hollow-green")
      Avwe.step(@world, 3)

      assert scenes(wren) == []

      scene = first_scene(wren)
      assert thing(scene, "pell").cell == scene.center
    end

    test "none is sent when nothing has changed" do
      wren = join("wren")
      first_scene(wren)

      # The first step hands the body to its controller, which is part of a scene.
      assert [%Scene{holder: :arbor}] = step_scenes(wren)

      Avwe.step(@world, 5)
      assert scenes(wren) == []
    end

    test "a walk is a scene a step, each after the percepts of its step" do
      odo = join("odo")
      start = first_scene(odo)

      {:ok, ref} = Session.act(odo, :go, target: "hollow-green")
      Avwe.step(@world, 1)

      assert [
               {:avwe_percepts, ^odo, [%Percept{intent: ^ref, type: :action_started}]},
               {:avwe_scene, ^odo, %Scene{center: {x1, y}}}
             ] = inbox(odo)

      {x0, ^y} = start.center
      assert x1 < x0
      _ = scenes(odo)

      xs =
        for _step <- 1..5 do
          assert [%Scene{center: {x, ^y}}] = step_scenes(odo)
          x
        end

      assert xs == Enum.sort(xs, :desc)
      assert Enum.uniq(xs) == xs
      assert hd(xs) < x1
    end

    test "someone coming into sight appears in the scene, and is followed home" do
      wren = join("wren")
      first_scene(wren)
      assert [%Scene{}] = step_scenes(wren)

      odo = plain("odo")
      {:ok, _ref} = Session.act(odo, :go, target: "hollow-green")

      # Odo's walk changes nothing Wren can see until he is within her sight.
      {taken, scene} = step_until_scene(wren)
      assert taken > 10
      assert %{kind: :body, cell: cell} = thing(scene, "odo")
      assert Space.distance(scene.center, cell) <= scene.radius

      assert [%Scene{} = nearer] = step_scenes(wren)
      assert {x, _y} = thing(nearer, "odo").cell
      assert x < elem(cell, 0)
    end

    test "two on the green see each other, at the cell and in the glyph each has" do
      wren = join("wren")
      tamsin = join("tamsin")
      seen_by_wren = first_scene(wren)
      seen_by_tamsin = first_scene(tamsin)

      assert %{cell: cell, glyph: glyph} = thing(seen_by_wren, "tamsin")
      assert cell == seen_by_tamsin.center
      assert glyph == seen_by_tamsin.you.glyph

      assert %{cell: cell, glyph: glyph} = thing(seen_by_tamsin, "wren")
      assert cell == seen_by_wren.center
      assert glyph == seen_by_wren.you.glyph
      assert seen_by_wren.you.glyph != seen_by_tamsin.you.glyph
    end

    test "dusk is a run of scenes, each different from the last, and fewer than its steps" do
      wren = join("wren")
      noon = first_scene(wren)
      assert thing(noon, "pell")
      assert [%Scene{}] = step_scenes(wren)

      Avwe.step(@world, 600)
      run = scenes(wren)
      night = List.last(run)

      radii = Enum.map(run, & &1.radius)
      assert radii == Enum.sort(radii, :desc)
      assert night.radius == 5.0
      assert night.light == 0.0
      refute thing(night, "pell")
      assert thing(night, "wren") == nil

      assert length(run) in 2..300

      assert run
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> not Scene.same_view?(a, b) end)
    end
  end

  describe "the hand-over" do
    test "a scene follows who holds the body, and asking for scenes keeps the body in hand" do
      wren = join("wren")
      first_scene(wren)

      # Each ask is presence: it arms a new idle timer, so the one that was
      # running goes off too late to take the body.
      for _n <- 1..5 do
        assert {:ok, %Scene{}} = Idle.presence(wren, fn -> Session.scene(wren) end)
      end

      assert [%Scene{holder: :arbor}] = step_scenes(wren)
      assert {:ok, [%{id: "wren", controller: :arbor}]} = bodies("wren")

      # Left alone, the timer goes off with no ask since: the session yields
      # the body to its routine, and the scene says so.
      Idle.expire(wren)
      assert [%Scene{holder: nil}] = step_scenes(wren)
      assert {:ok, [%{id: "wren", controller: :autopilot}]} = bodies("wren")
    end
  end

  defp bodies(id) do
    with {:ok, bodies} <- Avwe.bodies(@world), do: {:ok, Enum.filter(bodies, &(&1.id == id))}
  end
end
