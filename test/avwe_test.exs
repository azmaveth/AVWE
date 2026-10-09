defmodule AvweTest do
  use ExUnit.Case, async: false

  alias Avwe.{Calendar, Event}
  alias Avwe.Test.Fixtures

  @world :test_reach

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world, quire: Fixtures.ember_reach(), start: {813, day: 220, hour: 4})

    on_exit(fn -> Avwe.stop_world(@world) end)
  end

  test "a world starts from Quire at its start time" do
    assert Avwe.now(@world) == "813 AR, day 220, 04:00"
    assert {:ok, snapshot} = Avwe.snapshot(@world)
    assert snapshot.components.repr["mira-vale"].name == "Mira Vale"
  end

  test "stepping advances the clock and publishes a new snapshot" do
    assert {:ok, %{step: 60}} = Avwe.step(@world, 60)
    assert Avwe.now(@world) == "813 AR, day 220, 05:00"
  end

  test "subscribers receive events" do
    {:ok, _owner} = Avwe.subscribe(@world)
    Avwe.step(@world, 120)

    sunrise = Calendar.at(813, day: 220, hour: 6)

    # Each step's events come with the view of the state they happened in;
    # Mira is on her own here, so the sunrise step carries her stirring too.
    assert [view] =
             for(
               {:avwe_events, @world, events, view} <- batches(),
               Enum.any?(events, &match?(%Event{type: :sunrise, time: ^sunrise}, &1)),
               do: view
             )

    assert view.time == sunrise
  end

  test "warm_ground keeps the ground map of a world's terrain, without waiting for it" do
    warm = :warm_reach
    seed = System.unique_integer([:positive])

    {:ok, _pid} =
      Avwe.start_world(warm,
        quire: Fixtures.lantern_hollow(),
        terrain: [clay: [{"hollow-green", radius_cells: 3}]],
        seed: seed
      )

    on_exit(fn -> Avwe.stop_world(warm) end)

    {:ok, %{terrain: terrain}} = Avwe.snapshot(warm)
    refute Avwe.GroundCache.cached?(terrain)

    # It returns at once; the map, which takes about a second, comes after.
    {microseconds, :ok} = :timer.tc(fn -> Avwe.warm_ground(warm) end)
    assert microseconds < 250_000
    refute Avwe.GroundCache.cached?(terrain)

    assert Fixtures.eventually(fn -> Avwe.GroundCache.cached?(terrain) end, 10_000)
    assert :ok = Avwe.warm_ground(warm)
  end

  test "warm_ground has nothing to build for a world with no terrain, or none running" do
    flat = :flat_reach
    {:ok, _pid} = Avwe.start_world(flat, quire: Fixtures.lantern_hollow())
    on_exit(fn -> Avwe.stop_world(flat) end)

    assert :ok = Avwe.warm_ground(flat)
    assert :ok = Avwe.warm_ground(:no_such_world)
  end

  test "a subscriber hears of a step with no events only if it asked to hear of every step" do
    # Only the daylight runs here, so nothing happens between now and sunrise.
    hushed = :hushed_reach

    {:ok, _pid} =
      Avwe.start_world(hushed,
        quire: Fixtures.ember_reach(),
        start: {813, day: 220, hour: 4},
        systems: [Avwe.Systems.Daylight]
      )

    on_exit(fn -> Avwe.stop_world(hushed) end)

    parent = self()
    quiet = spawn_link(fn -> relay(parent, hushed, :quiet, false) end)
    steady = spawn_link(fn -> relay(parent, hushed, :steady, true) end)
    assert_receive {:subscribed, :quiet}
    assert_receive {:subscribed, :steady}

    Avwe.step(hushed, 1)
    Avwe.step(hushed, 1)

    assert_receive {:heard, :steady, [], %{step: 1}}
    assert_receive {:heard, :steady, [], %{step: 2}}
    refute_received {:heard, :quiet, _events, _view}

    # A step with events is told to both.
    Avwe.step(hushed, 120)
    assert_receive {:heard, :quiet, [%Event{type: :sunrise}], _view}
    assert_receive {:heard, :steady, [%Event{type: :sunrise}], _view}

    for pid <- [quiet, steady], do: send(pid, :stop)
  end

  # A process that subscribes as asked and passes on what it hears, tagged.
  defp relay(parent, world, tag, steps?) do
    {:ok, _owner} = Avwe.subscribe(world, steps: steps?)
    send(parent, {:subscribed, tag})
    relay_loop(parent, world, tag)
  end

  defp relay_loop(parent, world, tag) do
    receive do
      {:avwe_events, ^world, events, view} ->
        send(parent, {:heard, tag, events, view})
        relay_loop(parent, world, tag)

      :stop ->
        :ok
    end
  end

  defp batches do
    receive do
      {:avwe_events, _world, _events, _view} = batch -> [batch | batches()]
    after
      0 -> []
    end
  end

  test "the same world can't be started twice" do
    assert {:error, {:already_started, _pid}} =
             Avwe.start_world(@world, quire: Fixtures.ember_reach())
  end

  test "a world with neither a definition nor a Quire folder doesn't start" do
    assert {:error, :no_world_source} = Avwe.start_world(:nowhere)
  end
end
