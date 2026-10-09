defmodule Avwe.E2E.SystemIdsTest do
  @moduledoc """
  End to end through the public API and the disk: a saved world names its
  systems by id, so the module behind an id can move, and a world saved with a
  system that no module runs any more is refused in words.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0]
  import ExUnit.CaptureLog

  alias Avwe.{Region, RegionServer, Store, SystemTable}

  @moduletag :tmp_dir
  @world :hollow_system_ids
  @region {0, 0}

  defmodule Marker do
    @moduledoc false
    @behaviour Avwe.System

    # Writes who ran it into the world's environment.
    @impl Avwe.System
    def system_id, do: "test.e2e.marker/step"

    @impl Avwe.System
    def run(region, _tick), do: {Region.put_env(region, :ran, :marker), []}
  end

  defmodule Successor do
    @moduledoc false
    @behaviour Avwe.System

    # The module the marker moved to.
    @impl Avwe.System
    def system_id, do: "test.e2e.marker/step"

    @impl Avwe.System
    def run(region, _tick), do: {Region.put_env(region, :ran, :successor), []}
  end

  defmodule Tally do
    @moduledoc false
    @behaviour Avwe.System

    # Counts the times it was prepared, which a world must not do twice.
    @impl Avwe.System
    def system_id, do: "test.e2e.tally/step"

    @impl Avwe.System
    def prepare(region),
      do: Region.put_env(region, :prepared, Map.get(region.env, :prepared, 0) + 1)

    @impl Avwe.System
    def run(region, tick), do: {Region.put_env(region, :last, {tick.time, tick.dt}), []}
  end

  defmodule Vanishing do
    @moduledoc false
    @behaviour Avwe.System

    @impl Avwe.System
    def system_id, do: "test.e2e.vanishing/step"

    @impl Avwe.System
    def run(region, _tick), do: {region, []}
  end

  setup do
    on_exit(fn -> if Avwe.World.whereis(@world), do: Avwe.stop_world(@world) end)
  end

  defp start(tmp_dir, systems) do
    Avwe.start_world(@world,
      quire: lantern_hollow(),
      start: {1, hour: 12},
      data_dir: tmp_dir,
      systems: systems
    )
  end

  defp store_dir(tmp_dir), do: Path.join(tmp_dir, to_string(@world))

  test "a saved world resumes when the module that runs one of its systems has moved", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _pid} = start(tmp_dir, [Marker])
    Avwe.step(@world, 3)
    assert {:ok, %{env: %{ran: :marker}}} = Avwe.snapshot(@world)
    :ok = Avwe.stop_world(@world)

    # The system is the same, and lives in another module now.
    :ok = SystemTable.put("test.e2e.marker/step", Successor)

    assert {:ok, _pid} = start(tmp_dir, ["test.e2e.marker/step"])
    assert {:ok, %{step: 3}} = Avwe.snapshot(@world)
    Avwe.step(@world, 2)
    assert {:ok, %{step: 5, env: %{ran: :successor}}} = Avwe.snapshot(@world)
    {:ok, live} = RegionServer.state_hash(@world, @region)
    :ok = Avwe.stop_world(@world)

    # Nothing was snapshotted for it (the systems are the same ids), and the
    # whole history replays from its first snapshot to the same state.
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0]
    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    :ok = Store.close(store)

    assert Region.state_hash(rebuilt) == live
    assert rebuilt.systems == [{"test.e2e.marker/step", []}]

    SystemTable.put("test.e2e.marker/step", Marker)
  end

  test "a world resumed with another period for a system is not prepared again, and replays", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _pid} = start(tmp_dir, [Tally])
    Avwe.step(@world, 3)
    assert {:ok, %{env: %{prepared: 1}}} = Avwe.snapshot(@world)
    :ok = Avwe.stop_world(@world)

    {:ok, _pid} = start(tmp_dir, [{Tally, every: 120}])

    assert {:ok, %{step: 3, env: %{prepared: 1}}} = Avwe.snapshot(@world)

    Avwe.step(@world, 3)
    {:ok, live} = RegionServer.state_hash(@world, @region)
    :ok = Avwe.stop_world(@world)

    # The log from the change on belongs to the new period, so a snapshot was
    # written at once, and the world comes back from it to the same state.
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 3]
    assert {:ok, rebuilt} = Store.rebuild(store)
    :ok = Store.close(store)

    assert rebuilt.systems == [{"test.e2e.tally/step", [every: 120]}]
    assert Region.state_hash(rebuilt) == live
  end

  test "a world saved with a system that no module runs is refused, naming it", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _pid} = start(tmp_dir, [Vanishing])
    Avwe.step(@world, 3)
    :ok = Avwe.stop_world(@world)

    :persistent_term.erase({SystemTable, "test.e2e.vanishing/step"})

    log =
      capture_log(fn ->
        assert {:error,
                {:shutdown,
                 {:failed_to_start_child, _child,
                  {:store, {:unknown_systems, ["test.e2e.vanishing/step"]}}}}} =
                 start(tmp_dir, [])
      end)

    assert log =~
             "the world was saved with systems this build does not have: " <>
               "test.e2e.vanishing/step"

    assert log =~ "delete the world folder #{store_dir(tmp_dir)} to start over"
    assert Avwe.World.whereis(@world) == nil

    SystemTable.put("test.e2e.vanishing/step", Vanishing)
  end
end
