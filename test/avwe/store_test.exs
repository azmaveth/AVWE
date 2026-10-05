defmodule Avwe.StoreTest do
  use ExUnit.Case, async: true

  alias Avwe.{Intent, Region, Store}
  alias Avwe.Test.Ember

  @moduletag :tmp_dir
  @region {0, 0}

  setup %{tmp_dir: dir} do
    {:ok, store} = Store.open(dir, @region)
    %{store: store, dir: dir}
  end

  # Advances `region` the way `Avwe.RegionServer` does: log first, then step.
  defp logged_advance(store, region, steps) do
    {events, after_advance} = region |> Region.advance(steps) |> Region.drain_events()
    :ok = Store.append(store, Store.record(region, steps, events))
    after_advance
  end

  defp intent(body, verb, opts \\ []) do
    Intent.new(
      body,
      verb,
      Keyword.put_new(opts, :ref, "#{verb}-#{System.unique_integer([:positive])}")
    )
  end

  # Mira walks to the Dry Bend, says something and is told to stop in the same
  # step (so the order of her intents matters), then follows the channel up to
  # the source, with quiet stretches between.
  defp play(store, region) do
    region
    |> Region.submit(intent("mira-vale", :go, target: "the-dry-bend"))
    |> Region.submit(intent("mira-vale", :say, params: %{text: "Off to the bend."}))
    |> Region.submit(intent("mira-vale", :stop))
    |> then(&logged_advance(store, &1, 3))
    |> Region.submit(intent("mira-vale", :go, target: "the-dry-bend"))
    |> then(&logged_advance(store, &1, 20))
    |> Region.submit(intent("mira-vale", :follow, params: %{direction: :upstream}))
    |> then(&logged_advance(store, &1, 10))
    |> Region.submit(intent("mira-vale", :wait, params: %{for: 120}))
    |> then(&logged_advance(store, &1, 5))
  end

  describe "the log" do
    test "opening creates the region's folder and an empty log", %{store: store, dir: dir} do
      assert File.dir?(Path.join(dir, "0-0"))
      assert File.regular?(Path.join([dir, "0-0", "log"]))
      assert Store.records(store) == []
      assert Store.latest_snapshot(store) == :none
      assert Store.rebuild(store) == :none
    end

    test "appended records come back in order", %{store: store} do
      region = Ember.region()
      first = Store.record(region, 2, [])
      second = Store.record(Region.advance(region, 2), 1, [])
      third = Store.record(Region.advance(region, 3), 4, [])

      for record <- [first, second, third], do: :ok = Store.append(store, record)

      assert Store.records(store) == [first, second, third]
      assert Store.records_after(store, 2) == [second, third]
      assert Store.records_after(store, 3) == [third]
      assert {:avwe, 1, %{step: 0, time: time, dt: 60, steps: 2, intents: []}} = first
      assert time == region.time
    end

    test "the record carries the pending intents in submission order", %{store: store} do
      region =
        Ember.region()
        |> Region.submit(intent("mira-vale", :say, params: %{text: "one"}))
        |> Region.submit(intent("mira-vale", :say, params: %{text: "two"}))

      :ok = Store.append(store, Store.record(region, 1, []))

      assert [{:avwe, 1, %{intents: [%Intent{seq: 0}, %Intent{seq: 1}]}}] = Store.records(store)
    end

    test "a second handle on the same store sees the first one's records", %{
      store: store,
      dir: dir
    } do
      :ok = Store.append(store, Store.record(Ember.region(), 1, []))

      task =
        Task.async(fn ->
          {:ok, other} = Store.open(dir, @region)
          records = Store.records(other)
          :ok = Store.close(other)
          records
        end)

      assert [{:avwe, 1, %{step: 0}}] = Task.await(task)
      assert [{:avwe, 1, %{step: 0}}] = Store.records(store)
    end
  end

  describe "snapshots" do
    test "the step-0 snapshot and the newest N are kept", %{store: store, dir: dir} do
      region = Ember.region()
      :ok = Store.snapshot(store, region, keep: 3)

      Enum.reduce(1..7, region, fn _n, acc ->
        acc = Region.advance(acc, 1)
        :ok = Store.snapshot(store, acc, keep: 3)
        acc
      end)

      assert Store.snapshots(store) == [0, 5, 6, 7]
      assert File.exists?(Path.join([dir, "0-0", "snap-0000000000.bin"]))
      assert File.exists?(Path.join([dir, "0-0", "snap-0000000007.bin"]))
      refute File.exists?(Path.join([dir, "0-0", "snap-0000000004.bin"]))
    end

    test "the default keeps five besides the first", %{store: store} do
      region = Ember.region()

      Enum.reduce(0..9, region, fn _n, acc ->
        :ok = Store.snapshot(store, acc)
        Region.advance(acc, 1)
      end)

      assert Store.snapshots(store) == [0, 5, 6, 7, 8, 9]
    end

    test "the latest snapshot is the region as it was", %{store: store} do
      region = Ember.region() |> Region.advance(12)
      :ok = Store.snapshot(store, Ember.region())
      :ok = Store.snapshot(store, region)

      assert {:ok, saved} = Store.latest_snapshot(store)
      assert saved.step == 12
      assert Region.state_hash(saved) == Region.state_hash(region)
      assert {:ok, %Region{step: 0}} = Store.first_snapshot(store)
    end

    test "pending intents are left out, as if not yet submitted", %{store: store} do
      quiet = Ember.region()

      busy =
        quiet
        |> Region.submit(intent("mira-vale", :say, params: %{text: "one"}))
        |> Region.submit(intent("mira-vale", :say, params: %{text: "two"}))

      :ok = Store.snapshot(store, busy)
      assert {:ok, saved} = Store.latest_snapshot(store)
      assert saved.inbox == []
      assert Region.state_hash(saved) == Region.state_hash(quiet)

      # The advance that applies them re-submits them with the same seqs.
      live = logged_advance(store, busy, 1)
      assert {:ok, rebuilt} = Store.rebuild(store)
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end
  end

  describe "rebuilding" do
    test "replaying the log from the step-0 snapshot reproduces the live state", %{store: store} do
      start = Ember.region()
      :ok = Store.snapshot(store, start)
      live = play(store, start)

      assert live.step == 38
      assert Region.get(live, "mira-vale", :position) != Region.get(start, "mira-vale", :position)

      assert {:ok, rebuilt} = Store.rebuild_from_start(store)
      assert rebuilt.step == 38
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "rebuilding from a later snapshot gives the same state", %{store: store} do
      start = Ember.region()
      :ok = Store.snapshot(store, start)
      midway = play(store, start)
      :ok = Store.snapshot(store, midway)
      live = play(store, midway)

      assert {:ok, rebuilt} = Store.rebuild(store)
      assert {:ok, from_start} = Store.rebuild_from_start(store)
      assert rebuilt.step == 76
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
      assert Region.state_hash(from_start) == Region.state_hash(live)
    end

    test "intents in one step are applied in the order they were submitted", %{store: store} do
      start = Ember.region()
      :ok = Store.snapshot(store, start)

      # Go, then stop: she stops short. The other way round she'd be walking.
      live =
        start
        |> Region.submit(intent("mira-vale", :go, target: "the-dry-bend"))
        |> Region.submit(intent("mira-vale", :stop))
        |> then(&logged_advance(store, &1, 1))

      assert Region.get(live, "mira-vale", :action) == nil

      assert {:ok, rebuilt} = Store.rebuild_from_start(store)
      assert Region.get(rebuilt, "mira-vale", :action) == nil
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "rebuilding with no records gives the snapshot", %{store: store} do
      region = Ember.region() |> Region.advance(5)
      :ok = Store.snapshot(store, region)

      assert {:ok, rebuilt} = Store.rebuild(store)
      assert Region.state_hash(rebuilt) == Region.state_hash(region)
    end

    test "a gap between the snapshot and the log is an error", %{store: store} do
      region = Ember.region()
      :ok = Store.snapshot(store, region)
      :ok = Store.append(store, Store.record(Region.advance(region, 5), 1, []))

      assert Store.rebuild(store) == {:error, {:log_gap, 0, 5}}
    end
  end

  describe "errors" do
    test "a dir that can't be created", %{dir: dir} do
      blocked = Path.join(dir, "blocked")
      File.write!(blocked, "not a dir")

      assert {:error, {:mkdir, _path, reason}} = Store.open(blocked, @region)
      assert reason in [:eexist, :enotdir]
    end

    test "a corrupt log", %{dir: dir} do
      corrupt = Path.join(dir, "corrupt")
      File.mkdir_p!(Path.join(corrupt, "0-0"))
      File.write!(Path.join([corrupt, "0-0", "log"]), "this is not a disk_log")

      assert {:error, {:open_log, _file, {:not_a_log_file, _}}} = Store.open(corrupt, @region)
    end

    test "a corrupt snapshot", %{store: store, dir: dir} do
      :ok = Store.snapshot(store, Ember.region())
      File.write!(Path.join([dir, "0-0", "snap-0000000003.bin"]), "garbage")

      assert {:error, {:corrupt_snapshot, path}} = Store.latest_snapshot(store)
      assert String.ends_with?(path, "snap-0000000003.bin")
      assert {:error, {:corrupt_snapshot, _path}} = Store.rebuild(store)
      assert {:ok, %Region{step: 0}} = Store.rebuild_from_start(store)
    end
  end
end
