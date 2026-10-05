defmodule Avwe.E2E.PersistenceTest do
  @moduledoc """
  End to end through the public API: the Ember Reach persisting itself to a
  temporary data dir, played through sessions as agents use them.

  This is the M0 check from `docs/DESIGN.md`: replaying the log reproduces
  the same state hash. It also covers restarting a world from disk,
  recovering a crashed region, and persistence being off by default in tests.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures

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

  # The region's and the clock's pids; both restart when the region crashes.
  defp pids do
    for key <- [{:region, @world, @region}, {:clock, @world}] do
      case Registry.lookup(Avwe.Registry, key) do
        [{pid, _value}] -> pid
        [] -> nil
      end
    end
  end

  # Steps the clock gave each region one advance, so there is one record per tick.
  defp intents_per_record(records) do
    for {:avwe, 1, %{step: step, intents: intents}} <- records, intents != [] do
      {step, length(intents)}
    end
  end

  defp results(session), do: session |> percepts() |> Enum.filter(&(&1.kind == :result))

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
    records = Store.records(store)
    assert length(records) == 53
    assert Enum.all?(records, &match?({:avwe, 1, %{steps: 1, dt: 60}}, &1))
    assert intents_per_record(records) == [{0, 2}, {2, 2}, {27, 1}, {47, 1}]
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
    assert [{:avwe, 1, %{step: 53, steps: 1}}] = Store.records_after(store, 53)
    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert Region.state_hash(rebuilt) == live_hash()
    :ok = Store.close(store)
  end

  test "a crashed region comes back as it was after its last advance", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    sessions = play()
    hash = live_hash()
    [region | _clock] = before = pids()

    Process.exit(region, :kill)

    eventually(fn ->
      pids() |> Enum.zip(before) |> Enum.all?(fn {new, old} -> new not in [nil, old] end)
    end)

    assert live_hash() == hash
    assert {:ok, %{step: 53}} = Avwe.snapshot(@world)

    {:ok, _ref} = Session.act(sessions.mira, :say, params: %{text: "Still here."})
    Avwe.step(@world, 1)
    assert [%{outcome: :success}] = results(sessions.mira)
    assert ~s(Mira Vale says, "Still here.") in summaries(sessions.watcher)
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

  test "a world with no data dir writes nothing", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir, data_dir: nil)
    _sessions = play()

    assert File.ls!(tmp_dir) == []
  end
end
