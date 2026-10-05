defmodule Avwe.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Avwe.{Intent, Region, Store}
  alias Avwe.Test.Ember

  @moduletag :tmp_dir
  @region {0, 0}

  setup %{tmp_dir: dir} do
    {:ok, store} = Store.open(dir, @region)
    %{store: store, dir: dir}
  end

  # Submits `intent` the way `Avwe.RegionServer` does: queue it, then journal
  # it with the seq the region gave it.
  defp logged_submit(region, store, intent) do
    region = Region.submit(region, intent)
    :ok = Store.append(store, Store.submit_record(region.step, List.last(Region.pending(region))))
    region
  end

  # Advances `region` the way `Avwe.RegionServer` does: step, then log.
  defp logged_advance(region, store, steps) do
    {events, after_advance} = region |> Region.advance(steps) |> Region.drain_events()
    :ok = Store.append(store, Store.advance_record(region, steps, region.dt, events))
    after_advance
  end

  defp records!(store) do
    {:ok, records} = Store.records(store)
    records
  end

  # Runs `fun` in a process whose heap may not grow past `words`; the VM
  # kills it if it does, and that comes back as `{:killed, words}`.
  defp read_within(words, fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
        send(parent, {:read, self(), fun.()})
      end)

    receive do
      {:read, ^pid, result} -> result
      {:DOWN, ^ref, :process, ^pid, :killed} -> {:killed, words}
    after
      10_000 -> flunk("The read did not finish in time")
    end
  end

  defp snapshot_file(dir, step) do
    Path.join([dir, "0-0", "snap-" <> String.pad_leading("#{step}", 10, "0") <> ".bin"])
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
    |> logged_submit(store, intent("mira-vale", :go, target: "the-dry-bend"))
    |> logged_submit(store, intent("mira-vale", :say, params: %{text: "Off to the bend."}))
    |> logged_submit(store, intent("mira-vale", :stop))
    |> logged_advance(store, 3)
    |> logged_submit(store, intent("mira-vale", :go, target: "the-dry-bend"))
    |> logged_advance(store, 20)
    |> logged_submit(store, intent("mira-vale", :follow, params: %{direction: :upstream}))
    |> logged_advance(store, 10)
    |> logged_submit(store, intent("mira-vale", :wait, params: %{for: 120}))
    |> logged_advance(store, 5)
  end

  describe "the log" do
    test "opening creates the region's folder and an empty log", %{store: store, dir: dir} do
      assert File.dir?(Path.join(dir, "0-0"))
      assert File.regular?(Path.join([dir, "0-0", "log"]))
      assert Store.records(store) == {:ok, []}
      assert Store.latest_snapshot(store) == :none
      assert Store.rebuild(store) == :none
    end

    test "appended records come back in order", %{store: store} do
      region = Ember.region()
      first = Store.advance_record(region, 2, 60, [])
      second = Store.advance_record(Region.advance(region, 2), 1, 60, [])
      third = Store.advance_record(Region.advance(region, 3), 4, 60, [])

      for record <- [first, second, third], do: :ok = Store.append(store, record)

      assert Store.records(store) == {:ok, [first, second, third]}
      assert Store.records_after(store, 2) == {:ok, [second, third]}
      assert Store.records_after(store, 3) == {:ok, [third]}
      assert {:avwe, 2, {:advance, %{step: 0, time: time, dt: 60, steps: 2, events: []}}} = first
      assert time == region.time
    end

    test "an intent is journaled with the seq the region gave it", %{store: store} do
      region =
        Ember.region()
        |> logged_submit(store, intent("mira-vale", :say, params: %{text: "one"}))
        |> logged_submit(store, intent("mira-vale", :say, params: %{text: "two"}))

      assert [
               {:avwe, 2, {:submit, 0, %Intent{seq: 0, params: %{text: "one"}}}},
               {:avwe, 2, {:submit, 0, %Intent{seq: 1, params: %{text: "two"}}}}
             ] = records!(store)

      assert Region.pending(region) |> Enum.map(& &1.seq) == [0, 1]
    end

    # Twenty thousand advances before the snapshot's step, three after. The
    # tail is read in a process that may hold a quarter of a million words:
    # room for a `:disk_log` chunk's worth of records many times over, but
    # not for the head (some 460 000 words). A read that materialised the
    # log would be killed; one that drops the head chunk by chunk is not.
    test "records_after returns only the tail of a long log, without the head in memory", %{
      store: store
    } do
      region = Ember.region()
      head = 20_000

      records =
        for step <- 0..(head + 2) do
          Store.advance_record(%{region | step: step, time: region.time + step * 60}, 1, 60, [])
        end

      records
      |> Enum.chunk_every(5_000)
      |> Enum.each(fn chunk -> :ok = :disk_log.log_terms(store.log, chunk) end)

      assert Store.records_after(store, head) == {:ok, Enum.drop(records, head)}

      assert {:ok, [{:avwe, 2, {:advance, %{step: ^head}}} | _rest]} =
               Store.records_after(store, head)

      assert read_within(250_000, fn -> Store.records_after(store, head) end) ==
               {:ok, Enum.drop(records, head)}
    end

    test "a second handle on the same store sees the first one's records", %{
      store: store,
      dir: dir
    } do
      :ok = Store.append(store, Store.advance_record(Ember.region(), 1, 60, []))

      task =
        Task.async(fn ->
          {:ok, other} = Store.open(dir, @region)
          records = records!(other)
          :ok = Store.close(other)
          records
        end)

      assert [{:avwe, 2, {:advance, %{step: 0}}}] = Task.await(task)
      assert [{:avwe, 2, {:advance, %{step: 0}}}] = records!(store)
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
      assert Path.wildcard(Path.join([dir, "0-0", "*.tmp"])) == []
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
        |> logged_submit(store, intent("mira-vale", :say, params: %{text: "one"}))
        |> logged_submit(store, intent("mira-vale", :say, params: %{text: "two"}))

      :ok = Store.snapshot(store, busy)
      assert {:ok, saved} = Store.latest_snapshot(store)
      assert saved.inbox == []
      assert Region.state_hash(saved) == Region.state_hash(quiet)

      # Their submit records re-submit them with the same seqs.
      live = logged_advance(busy, store, 1)
      assert {:ok, rebuilt} = Store.rebuild(store)
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "autopilot's intents are kept by their ref, whoever queued them", %{store: store} do
      # The system's own intent (never journaled) stays; a journaled one
      # claiming to be autopilot's does not, and neither does a human's.
      quiet = Ember.region()

      busy =
        quiet
        |> Region.submit(
          intent("mira-vale", :wait, ref: "auto-mira-vale-0", controller: :autopilot)
        )
        |> logged_submit(
          store,
          intent("mira-vale", :say, params: %{text: "one"}, controller: :autopilot)
        )
        |> logged_submit(
          store,
          intent("mira-vale", :say, params: %{text: "two"}, controller: :human)
        )

      :ok = Store.snapshot(store, busy)
      assert {:ok, saved} = Store.latest_snapshot(store)
      assert [%{ref: "auto-mira-vale-0", seq: 0}] = saved.inbox
      assert saved.next_seq == 1

      live = logged_advance(busy, store, 1)
      assert {:ok, rebuilt} = Store.rebuild(store)
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "a snapshot is the region wrapped in its version tag", %{store: store, dir: dir} do
      region = Ember.region() |> Region.advance(3)
      :ok = Store.snapshot(store, region)

      assert {:avwe_snapshot, 1, %Region{step: 3} = saved} =
               dir |> snapshot_file(3) |> File.read!() |> :erlang.binary_to_term()

      assert Region.state_hash(saved) == Region.state_hash(region)
    end

    test "a snapshot with another version's tag is refused, naming the file", %{
      store: store,
      dir: dir
    } do
      region = Ember.region()
      newer = snapshot_file(dir, 3)
      File.write!(newer, :erlang.term_to_binary({:avwe_snapshot, 2, region}))

      assert Store.latest_snapshot(store) ==
               {:error, {:unknown_snapshot, newer, {:avwe_snapshot, 2}}}

      # The format from before the tag: a bare region.
      untagged = snapshot_file(dir, 4)
      File.write!(untagged, :erlang.term_to_binary(region))

      assert Store.latest_snapshot(store) == {:error, {:unknown_snapshot, untagged, :untagged}}
    end

    test "a half-written snapshot is removed on open", %{store: store, dir: dir} do
      :ok = Store.snapshot(store, Ember.region())
      tmp = Path.join([dir, "0-0", "snap-0000000005.bin.tmp"])
      File.write!(tmp, "half")

      log =
        capture_log(fn ->
          {:ok, reader} = Store.open(dir, @region)
          :ok = Store.close(reader)
          assert File.exists?(tmp), "a reader must leave a .tmp alone"

          {:ok, owner} = Store.open(dir, @region, owner: true)
          :ok = Store.close(owner)
        end)

      refute File.exists?(tmp)
      assert log =~ "half-written snapshot"
      assert Store.snapshots(store) == [0]
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
        |> logged_submit(store, intent("mira-vale", :go, target: "the-dry-bend"))
        |> logged_submit(store, intent("mira-vale", :stop))
        |> logged_advance(store, 1)

      assert Region.get(live, "mira-vale", :action) == nil

      assert {:ok, rebuilt} = Store.rebuild_from_start(store)
      assert Region.get(rebuilt, "mira-vale", :action) == nil
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "an intent journaled but not yet applied is pending again after a rebuild", %{
      store: store
    } do
      start = Ember.region()
      :ok = Store.snapshot(store, start)

      live =
        start
        |> logged_advance(store, 2)
        |> logged_submit(store, intent("mira-vale", :say, params: %{text: "Not yet."}))

      assert {:ok, rebuilt} = Store.rebuild(store)
      assert rebuilt.step == 2
      assert [%Intent{params: %{text: "Not yet."}}] = Region.pending(rebuilt)
      assert Region.pending(rebuilt) == Region.pending(live)
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
    end

    test "an advance is replayed with the dt it was logged with", %{store: store} do
      start = Ember.region()
      :ok = Store.snapshot(store, start)

      :ok =
        Store.append(
          store,
          {:avwe, 2, {:advance, %{step: 0, time: start.time, dt: 3_600, steps: 2, events: []}}}
        )

      assert {:ok, rebuilt} = Store.rebuild(store)
      assert rebuilt.step == 2
      assert rebuilt.time == start.time + 2 * 3_600
      assert Region.state_hash(rebuilt) == Region.state_hash(Region.advance(start, 2, dt: 3_600))
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
      :ok = Store.append(store, Store.advance_record(Region.advance(region, 5), 1, 60, []))

      assert Store.rebuild(store) == {:error, {:log_gap, 0, 5}}
    end

    test "an intent journaled at the wrong step is a gap too", %{store: store} do
      region = Ember.region()
      :ok = Store.snapshot(store, region)
      :ok = Store.append(store, Store.submit_record(3, intent("mira-vale", :stop)))

      assert Store.rebuild(store) == {:error, {:log_gap, 0, 3}}
    end

    test "an intent whose logged seq the region wouldn't give it is an error", %{store: store} do
      region = Ember.region()
      :ok = Store.snapshot(store, region)
      :ok = Store.append(store, Store.submit_record(0, %{intent("mira-vale", :stop) | seq: 4}))

      assert Store.rebuild(store) == {:error, {:seq_mismatch, 0, 4, 0}}
    end

    test "a version-1 record is rejected", %{store: store} do
      region = Ember.region()
      :ok = Store.snapshot(store, region)
      old = {:avwe, 1, %{step: 0, time: region.time, dt: 60, steps: 1, intents: [], events: []}}
      :ok = :disk_log.log(store.log, old)

      assert Store.rebuild(store) == {:error, {:unknown_record, old}}
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

    test "a corrupt latest snapshot is skipped for an older one", %{store: store, dir: dir} do
      start = Ember.region()
      :ok = Store.snapshot(store, start)
      midway = play(store, start)
      :ok = Store.snapshot(store, midway)
      live = play(store, midway)

      latest = Path.join([dir, "0-0", "snap-0000000038.bin"])
      File.write!(latest, binary_part(File.read!(latest), 0, 100))

      assert {:error, {:corrupt_snapshot, ^latest}} = Store.latest_snapshot(store)

      log =
        capture_log(fn ->
          assert {:ok, rebuilt} = Store.rebuild(store)
          assert rebuilt.step == 76
          assert Region.state_hash(rebuilt) == Region.state_hash(live)
        end)

      assert log =~ "Skipping snapshot #{latest}"
      assert {:ok, from_start} = Store.rebuild_from_start(store)
      assert Region.state_hash(from_start) == Region.state_hash(live)
    end

    test "it is an error only when no snapshot decodes", %{store: store, dir: dir} do
      :ok = Store.snapshot(store, Ember.region())
      File.write!(Path.join([dir, "0-0", "snap-0000000000.bin"]), "garbage")
      File.write!(Path.join([dir, "0-0", "snap-0000000003.bin"]), "garbage")

      capture_log(fn ->
        assert {:error, {:corrupt_snapshot, path}} = Store.rebuild(store)
        assert String.ends_with?(path, "snap-0000000000.bin")
      end)
    end

    test "a latest snapshot of an unknown version is skipped for an older one", %{
      store: store,
      dir: dir
    } do
      start = Ember.region()
      :ok = Store.snapshot(store, start)
      midway = play(store, start)
      :ok = Store.snapshot(store, midway)
      live = play(store, midway)

      latest = snapshot_file(dir, 38)
      File.write!(latest, :erlang.term_to_binary({:avwe_snapshot, 2, midway}))

      log =
        capture_log(fn ->
          assert {:ok, rebuilt} = Store.rebuild(store)
          assert rebuilt.step == 76
          assert Region.state_hash(rebuilt) == Region.state_hash(live)
        end)

      assert log =~
               "Skipping snapshot #{latest}: {:unknown_snapshot, #{inspect(latest)}, {:avwe_snapshot, 2}}"
    end

    test "it is an error when every snapshot is of an unknown version", %{store: store, dir: dir} do
      region = Ember.region()
      :ok = Store.snapshot(store, region)
      first = snapshot_file(dir, 0)
      File.write!(first, :erlang.term_to_binary({:avwe_snapshot, 2, region}))
      File.write!(snapshot_file(dir, 3), :erlang.term_to_binary({:avwe_snapshot, 2, region}))

      capture_log(fn ->
        assert Store.rebuild(store) == {:error, {:unknown_snapshot, first, {:avwe_snapshot, 2}}}
      end)
    end
  end
end
