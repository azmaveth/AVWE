defmodule Avwe.E2E.PersistenceTest do
  @moduledoc """
  End to end through the public API: the Ember Reach persisting itself to a
  temporary data dir, played through sessions as agents use them.

  This is the M0 check from `docs/DESIGN.md`: replaying the log reproduces
  the same state hash. It also covers restarting a world from disk,
  recovering a crashed region (with the intents it had accepted), changing
  the rules on restart, and persistence being off by default in tests.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import ExUnit.CaptureLog

  alias Avwe.{Region, RegionServer, Session, Store}

  @moduletag :tmp_dir
  @world :ember_persist
  @region {0, 0}

  defp start(tmp_dir, overrides \\ []) do
    opts = ember_reach_opts(Keyword.merge([data_dir: tmp_dir], overrides))
    {:ok, _pid} = Avwe.start_world(@world, opts)
    :ok
  end

  defp store_dir(tmp_dir), do: Path.join(tmp_dir, to_string(@world))

  defp live_hash do
    {:ok, hash} = RegionServer.state_hash(@world, @region)
    hash
  end

  defp records(tmp_dir) do
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, records} = Store.records(store)
    :ok = Store.close(store)
    records
  end

  # The region's and the clock's pids; both restart when the region crashes.
  defp pids do
    for key <- [{:region, @world, @region}, {:clock, @world}] do
      case Registry.lookup(Avwe.Registry, key) do
        [{pid, _value}] -> pid
        [] -> nil
      end
    end
  end

  # Kills the region and waits for the supervisor to bring it and the clock back.
  defp crash_region do
    [region | _clock] = before = pids()
    Process.exit(region, :kill)

    eventually(fn ->
      pids() |> Enum.zip(before) |> Enum.all?(fn {new, old} -> new not in [nil, old] end)
    end)
  end

  # How many intents were journaled at each step that had any.
  defp submits_per_step(records) do
    records
    |> Enum.flat_map(fn
      {:avwe, 2, {:submit, step, _intent}} -> [step]
      _advance -> []
    end)
    |> Enum.frequencies()
    |> Enum.sort()
  end

  defp results(session), do: session |> percepts() |> Enum.filter(&(&1.kind == :result))

  defp light do
    {:ok, %{env: %{light: light}}} = Avwe.snapshot(@world)
    light
  end

  # Mira sets off for the bend but is stopped in the same step (order matters),
  # then really goes, talks, follows the channel up to the source, and waits.
  defp play do
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, watcher} = Avwe.connect(@world)

    {:ok, _ref} = Session.act(mira, :go, target: "the-dry-bend")
    {:ok, _ref} = Session.act(mira, :stop)
    Avwe.step(@world, 2)
    {:ok, _ref} = Session.act(mira, :go, target: "the-dry-bend")
    {:ok, _ref} = Session.act(mira, :say, params: %{text: "To the bend, then upstream."})
    Avwe.step(@world, 25)
    {:ok, _ref} = Session.act(mira, :follow, params: %{direction: :upstream})
    Avwe.step(@world, 20)
    {:ok, _ref} = Session.act(mira, :wait, params: %{for: 300})
    Avwe.step(@world, 6)

    assert Enum.any?(summaries(mira), &String.starts_with?(&1 || "", "You find The Source."))
    assert "Mira Vale leaves, heading upstream." in summaries(watcher)
    assert {:ok, %{here: %{name: "The Source"}}} = Session.look(mira)

    %{mira: mira, watcher: watcher}
  end

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> Avwe.stop_world(@world) end)
    %{tmp_dir: tmp_dir}
  end

  test "replaying the log from the step-0 snapshot reproduces the live state hash", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    _sessions = play()

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, records} = Store.records(store)
    advances = Enum.filter(records, &match?({:avwe, 2, {:advance, _entry}}, &1))
    assert length(records) == 59
    assert length(advances) == 53
    assert Enum.all?(advances, &match?({:avwe, 2, {:advance, %{steps: 1, dt: 60}}}, &1))
    assert submits_per_step(records) == [{0, 2}, {2, 2}, {27, 1}, {47, 1}]
    assert Store.snapshots(store) == [0]

    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert rebuilt.step == 53
    assert Region.state_hash(rebuilt) == live_hash()
    :ok = Store.close(store)
  end

  test "a world started again from the same data dir carries on where it stopped", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    sessions = play()
    now = Avwe.now(@world)
    hash = live_hash()
    :ok = Session.close(sessions.mira)
    :ok = Avwe.stop_world(@world)

    :ok = start(tmp_dir)

    assert {:ok, %{step: 53}} = Avwe.snapshot(@world)
    assert Avwe.now(@world) == now
    assert live_hash() == hash

    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    assert {:ok, %{here: %{name: "The Source"}}} = Session.look(mira)

    # And it keeps going, and keeps logging, from there.
    assert {:ok, %{step: 54}} = Avwe.step(@world, 1)
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert {:ok, [{:avwe, 2, {:advance, %{step: 53, steps: 1}}}]} = Store.records_after(store, 53)
    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert Region.state_hash(rebuilt) == live_hash()
    :ok = Store.close(store)
  end

  test "a crashed region comes back as it was after its last advance", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    sessions = play()
    hash = live_hash()

    crash_region()

    assert live_hash() == hash
    assert {:ok, %{step: 53}} = Avwe.snapshot(@world)

    {:ok, _ref} = Session.act(sessions.mira, :say, params: %{text: "Still here."})
    Avwe.step(@world, 1)
    assert [%{outcome: :success}] = results(sessions.mira)
    assert ~s(Mira Vale says, "Still here.") in summaries(sessions.watcher)
  end

  test "an intent accepted before a crash still gets its one result", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, ref} = Session.act(mira, :say, params: %{text: "Before the crash."})

    crash_region()

    assert [{:avwe, 2, {:submit, 0, %{ref: ^ref, seq: 0}}}] = records(tmp_dir)
    Avwe.step(@world, 1)
    assert [%{intent: ^ref, outcome: :success}] = results(mira)

    Avwe.step(@world, 1)
    assert results(mira) == []
  end

  test "an intent accepted before the world stops still gets its one result", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, ref} = Session.act(mira, :say, params: %{text: "Before the stop."})
    :ok = Avwe.stop_world(@world)

    :ok = start(tmp_dir)
    Avwe.step(@world, 1)
    assert [%{intent: ^ref, outcome: :success}] = results(mira)

    Avwe.step(@world, 1)
    assert results(mira) == []
  end

  test "snapshots are taken every snapshot_every steps and the latest one is resumed from", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir, snapshot_every: 10)
    _sessions = play()

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 10, 20, 30, 40, 50]
    assert {:ok, %Region{step: 53}} = Store.rebuild(store)
    assert {:ok, %Region{step: 50}} = Store.latest_snapshot(store)
    :ok = Store.close(store)
  end

  test "an advance that crosses a multiple of snapshot_every snapshots at its end", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir, snapshot_every: 10)
    assert {:ok, %{step: 15}} = RegionServer.advance(@world, @region, 15)
    assert {:ok, %{step: 30}} = RegionServer.advance(@world, @region, 15)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 15, 30]
    :ok = Store.close(store)
  end

  test "snapshot_keep limits the snapshots kept besides the first", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir, snapshot_every: 10, snapshot_keep: 2)
    Avwe.step(@world, 50)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 40, 50]
    :ok = Store.close(store)
  end

  test "a log with no snapshot to replay it onto stops the world from starting", %{
    tmp_dir: tmp_dir
  } do
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    :ok = Store.append(store, Store.advance_record(Region.new(id: @region, seed: 1), 1, 60, []))
    :ok = Store.close(store)

    assert {:error,
            {:shutdown, {:failed_to_start_child, _child, {:store, :log_without_snapshot}}}} =
             Avwe.start_world(@world, ember_reach_opts(data_dir: tmp_dir))

    assert Avwe.World.whereis(@world) == nil
  end

  test "the systems a world is restarted with replace the saved ones", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir, snapshot_every: 100)
    assert light() == 0.0
    :ok = Avwe.stop_world(@world)

    # Without Daylight the sun doesn't rise at 06:00 (step 120 from 04:00).
    :ok = start(tmp_dir, snapshot_every: 100, systems: [])
    {:ok, watcher} = Avwe.connect(@world)
    Avwe.step(@world, 125)
    refute "The sun rises." in summaries(watcher)
    assert light() == 0.0
    :ok = Avwe.stop_world(@world)

    # Put back, it picks up the sky where the world is: the snapshot at step
    # 100 was saved without it, and the log since then replays without it.
    :ok = start(tmp_dir, snapshot_every: 100)
    assert {:ok, %{step: 125}} = Avwe.snapshot(@world)
    assert light() == 0.0
    Avwe.step(@world, 1)
    assert light() > 0.0
  end

  test "the saved seed is kept over the one the world is restarted with", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    Avwe.step(@world, 5)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    log = capture_log(fn -> :ok = start(tmp_dir, seed: 12_345) end)

    assert log =~ "ignoring :seed 12345; the world's seed is"
    assert live_hash() == hash
  end

  test "a world with no data dir writes nothing", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir, data_dir: nil)
    _sessions = play()

    assert File.ls!(tmp_dir) == []
  end
end
