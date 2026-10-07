defmodule Avwe.E2E.WatchTest do
  @moduledoc """
  End to end through `Avwe.Session`, as a page that watches uses it: a spectator
  opened with `scenes: true`, in the Ember Reach on day 200 of 812 AR, an hour
  before the river's source fails, and in Lantern Hollow, which has no terrain.
  Worlds are on a manual clock, stepped a minute at a time as a live one goes.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures

  alias Avwe.{GroundCache, Percept, Session, WorldGround, WorldScene}

  @ember :ember_watch
  @hollow :hollow_watch
  @start {812, day: 200, hour: 14}

  setup do
    on_exit(fn ->
      Avwe.stop_world(@ember)
      Avwe.stop_world(@hollow)
    end)
  end

  defp ember(overrides \\ []) do
    {:ok, _pid} = Avwe.start_world(@ember, ember_reach_opts([start: @start] ++ overrides))
    :ok
  end

  defp hollow do
    {:ok, _pid} = Avwe.start_world(@hollow, quire: lantern_hollow(), start: {1, hour: 12})
    :ok
  end

  defp watch(world \\ @ember, opts \\ []) do
    {:ok, session} = Avwe.connect(world, [scenes: true] ++ opts)
    session
  end

  # Everything the session has sent the calling process, in the order it came.
  defp inbox(session) do
    receive do
      {:avwe_percepts, ^session, _percepts} = message -> [message | inbox(session)]
      {:avwe_scene, ^session, _scene} = message -> [message | inbox(session)]
    after
      0 -> []
    end
  end

  # Steps the world a minute at a time, with the session caught up after each,
  # and gives what it sent, in order.
  defp minutes(session, world, count) do
    Enum.flat_map(1..count, fn _minute ->
      Avwe.step(world, 1)
      _body = Session.body(session)
      inbox(session)
    end)
  end

  defp scenes(messages), do: for({:avwe_scene, _session, scene} <- messages, do: scene)
  defp heard(messages), do: for({:avwe_percepts, _session, ps} <- messages, p <- ps, do: p)
  defp silent(scene), do: Enum.count(scene.overlays.water, & &1.silent)

  describe "a spectator with scenes" do
    setup do
      ember()
    end

    test "is given the whole valley: everyone in it, the river by reach, the heat, and the smoke" do
      watcher = watch()

      assert {:ok, %WorldScene{} = scene} = Session.scene(watcher)
      assert Enum.any?(scene.things, &(&1.id == "mira-vale" and &1.kind == :body))
      assert length(scene.overlays.water) == 23
      assert silent(scene) == 0
      assert length(scene.overlays.heat.rows) == 256
      assert scene.overlays.smoke == []
    end

    test "is given the ground of the whole map once, and it has the river's reaches in it" do
      watcher = watch()

      assert {:ok, %WorldGround{width: 256, height: 256} = ground} = Session.ground(watcher)
      assert length(ground.rows) == 256
      assert length(ground.reaches) == 23
      assert Enum.all?(ground.reaches, &(&1 != []))
      assert {:ok, ^ground} = Session.ground(watcher)
    end

    test "holds nothing: the bodies are free, and stay as they were when it goes" do
      watchers = [watch(), watch()]
      {:ok, bodies} = Avwe.bodies(@ember)
      assert Enum.all?(bodies, &(&1.taken == false))

      for watcher <- watchers, do: Session.close(watcher)
      {:ok, bodies} = Avwe.bodies(@ember)
      assert Enum.all?(bodies, &(&1.taken == false))
    end

    test "is sent a scene as the river falls silent from the source down, a scene to each change" do
      watcher = watch()
      {:ok, first} = Session.scene(watcher)
      messages = minutes(watcher, @ember, 4 * 60)
      scenes = scenes(messages)

      counts = Enum.map([first | scenes], &silent/1)
      assert counts == Enum.sort(counts)
      assert hd(counts) == 0 and List.last(counts) == 23
      assert counts |> Enum.uniq() |> length() > 5

      # The silence moves downstream: the silent reaches are always the first ones.
      for scene <- scenes do
        flags = Enum.map(scene.overlays.water, & &1.silent)
        assert flags == Enum.sort(flags, :desc)
      end

      # A scene is sent when it differs from the last, and only then.
      for {a, b} <- Enum.zip([first | scenes], scenes) do
        refute WorldScene.same_view?(a, b)
      end
    end

    test "is told what the telnet watcher is told, and each scene comes after the percepts of its step" do
      watcher = watch()
      {:ok, _first} = Session.scene(watcher)
      messages = minutes(watcher, @ember, 4 * 60)

      lines = messages |> heard() |> Enum.map(& &1.summary)

      for line <- [
            "The spring stops welling up.",
            "The river falls silent near The Source.",
            "The river falls silent near The Dry Bend.",
            "The river falls silent near Ember Reach.",
            "The river falls silent near Willow Docks."
          ] do
        assert line in lines, line
      end

      # No percept comes after a scene that is already of its step or later.
      {_time, late} =
        Enum.reduce(messages, {nil, []}, fn
          {:avwe_scene, _s, scene}, {_time, late} ->
            {scene.time, late}

          {:avwe_percepts, _s, ps}, {time, late} ->
            {time, late ++ for(%Percept{time: t} = p <- ps, time != nil and t <= time, do: p)}
        end)

      assert late == []
    end

    # Stepped all at once, the world is far ahead of the session by the time it
    # handles the first step's message. A scene is never ahead of the words about
    # it: the session leaves a snapshot that is already ahead to the message that
    # comes with its own percepts, so no percept follows a scene that shows its
    # step, and the last scene is the world as it ended.
    test "is sent a burst of steps as the newest scene, and never one ahead of the percepts" do
      watcher = watch()
      {:ok, _first} = Session.scene(watcher)

      # The session is held back while the world runs on, so that every step's
      # message is waiting and the snapshot is far ahead of the first of them.
      :ok = :sys.suspend(watcher)
      Avwe.step(@ember, 4 * 60)
      :ok = :sys.resume(watcher)
      _body = Session.body(watcher)
      messages = inbox(watcher)

      scenes = scenes(messages)
      assert scenes != []
      assert silent(List.last(scenes)) == 23
      assert {:ok, %{time: time}} = Avwe.snapshot(@ember)
      assert List.last(scenes).time == time

      late =
        messages
        |> Enum.reduce({nil, []}, fn
          {:avwe_scene, _s, scene}, {_time, late} ->
            {scene.time, late}

          {:avwe_percepts, _s, ps}, {time, late} ->
            {time, late ++ Enum.filter(ps, &(time != nil and &1.time <= time))}
        end)
        |> elem(1)

      assert late == []

      assert "The river falls silent near Willow Docks." in Enum.map(
               heard(messages),
               & &1.summary
             )
    end

    test "has no scene or ground when it did not ask for scenes, as telnet's and MCP's watchers have none" do
      {:ok, plain} = Avwe.connect(@ember)

      assert {:ok, nil} = Session.scene(plain)
      assert {:ok, nil} = Session.ground(plain)
      Avwe.step(@ember, 3)
      _body = Session.body(plain)
      assert scenes(inbox(plain)) == []
    end

    test "is not a body's session: an embodied one still has its own scene, and no ground to give" do
      {:ok, mira} = Avwe.connect(@ember, body: "mira-vale", controller: :human, scenes: true)

      assert {:ok, %Avwe.Scene{}} = Session.scene(mira)
      assert {:ok, nil} = Session.ground(mira)
    end
  end

  describe "the ground of a land nobody has built" do
    test "is built while the session goes on, and given when it is ready" do
      # A land of its own (its seed is its own), so that nothing has built it.
      ember(seed: 424_242)
      {:ok, %{terrain: terrain}} = Avwe.snapshot(@ember)
      refute GroundCache.world_cached?(terrain)

      watcher = watch()
      task = Task.async(fn -> Session.ground(watcher) end)

      # The call has reached the session, which is building the ground (about a
      # second and a quarter) and has not answered it.
      Process.sleep(150)
      assert Task.yield(task, 0) == nil

      # And the session goes on: it answers another call at once, where one that
      # built the ground itself would keep the caller waiting for the rest of it.
      {microseconds, nil} = :timer.tc(fn -> Session.body(watcher) end)
      assert microseconds < 700_000
      assert Task.yield(task, 0) == nil

      assert {:ok, %WorldGround{width: 256}} = Task.await(task, 20_000)
      assert GroundCache.world_cached?(terrain)
    end
  end

  describe "a spectator in a world with no terrain" do
    setup do
      hollow()
    end

    test "has what the world has: its people, no river, no heat and no smoke, and no ground" do
      watcher = watch(@hollow)

      assert {:ok, %WorldScene{} = scene} = Session.scene(watcher)

      assert scene.things |> Enum.filter(&(&1.kind == :body)) |> Enum.map(& &1.id) |> Enum.sort() ==
               ~w(odo pell tamsin wren)

      assert scene.overlays == %{water: [], heat: nil, smoke: []}
      assert {:ok, nil} = Session.ground(watcher)
    end

    test "is sent nothing while nothing changes" do
      watcher = watch(@hollow)
      {:ok, _scene} = Session.scene(watcher)

      Avwe.step(@hollow, 5)
      _body = Session.body(watcher)

      assert scenes(inbox(watcher)) == []
    end

    test "is sent a scene when somebody walks" do
      watcher = watch(@hollow)
      {:ok, first} = Session.scene(watcher)
      {:ok, odo} = Avwe.connect(@hollow, body: "odo", controller: :arbor)
      {:ok, _ref} = Session.act(odo, :go, target: "hollow-green")

      messages = minutes(watcher, @hollow, 3)

      assert [%WorldScene{} = moved | _] = scenes(messages)
      refute WorldScene.same_view?(first, moved)

      assert Enum.find(moved.things, &(&1.id == "odo")).cell !=
               Enum.find(first.things, &(&1.id == "odo")).cell
    end
  end
end
