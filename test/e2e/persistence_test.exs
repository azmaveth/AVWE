defmodule Avwe.E2E.PersistenceTest do
  @moduledoc """
  End to end through the public API: the Ember Reach persisting itself to a
  temporary data dir, played through sessions as agents use them.

  This is the M0 check from `docs/DESIGN.md`: replaying the log reproduces
  the same state hash. It also covers restarting a world from disk,
  recovering a crashed region (with the intents it had accepted), changing
  the rules on restart, and persistence being off by default in tests.

  The world is the Ember Reach with a light wind from the south-west, so
  that when Mira lights the kiln-house hearth and sets off for the bend she
  walks downwind through its smoke: fire, smoke, her nose and the warmed
  ground all go through the store and back.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import ExUnit.CaptureLog

  alias Avwe.{Region, RegionServer, Session, Store}

  @moduletag :tmp_dir
  @world :ember_persist
  @region {0, 0}
  @wind [from: "south-west", m_s: 0.2]
  @hearth "town-hearth"

  defp start(tmp_dir, overrides \\ []) do
    opts =
      ember_reach_opts(Keyword.merge([data_dir: tmp_dir, climate: [wind: @wind]], overrides))

    {:ok, _pid} = Avwe.start_world(@world, opts)
    :ok
  end

  defp store_dir(tmp_dir), do: Path.join(tmp_dir, to_string(@world))

  defp live_hash do
    {:ok, hash} = RegionServer.state_hash(@world, @region)
    hash
  end

  # The live region's fire, smoke, noses and heat, as published after its
  # last advance: what a restart or a replay must give back exactly.
  defp fire_state(%{components: components, fields: fields}) do
    %{
      hearth: components[:hearth],
      nose: components[:nose],
      puffs: fields.smoke.puffs,
      heat: fields.heat
    }
  end

  defp live_fire_state do
    {:ok, snapshot} = Avwe.snapshot(@world)
    fire_state(snapshot)
  end

  # The summaries of the percepts in `percepts` that came through the nose.
  defp smells(percepts) do
    percepts |> Enum.filter(&(&1.modality == :smell)) |> Enum.map(& &1.summary)
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

  # The log lines mentioning `text`, without the logger's own prefix.
  defp lines(log, text) do
    for line <- String.split(log, "\n"),
        line =~ text,
        do: line |> String.split("] ") |> List.last()
  end

  # A warning's hearths as `%{id => [fuel_kg, power_w]}`, whatever order the
  # keys were printed in.
  defp hearth_values(text) do
    for [id, body] <- Regex.scan(~r/"([^"]+)" => %\{([^}]*)\}/, text, capture: :all_but_first),
        into: %{} do
      {id,
       for key <- ["fuel_kg", "power_w"] do
         [value] = Regex.run(~r/#{key}: ([\d.]+)/, body, capture: :all_but_first)
         String.to_float(value)
       end}
    end
  end

  defp light do
    {:ok, %{env: %{light: light}}} = Avwe.snapshot(@world)
    light
  end

  # Mira lights the kiln-house hearth, smells its smoke, and douses it a few
  # minutes later. She sets off for the bend but is stopped in the same step
  # (order matters), then really goes, talks, follows the channel up to the
  # source, and waits; the smoke thins behind her on the way.
  defp play do
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, watcher} = Avwe.connect(@world)

    {:ok, _ref} = Session.act(mira, :kindle)
    Avwe.step(@world, 1)
    lit = percepts(mira)
    assert "You light the kiln-house hearth." in Enum.map(lit, & &1.summary)
    assert smells(lit) == ["You smell woodsmoke on the wind from the south-west."]
    Avwe.step(@world, 2)
    {:ok, _ref} = Session.act(mira, :douse)
    Avwe.step(@world, 1)
    doused = percepts(mira)
    assert "You douse the kiln-house hearth." in Enum.map(doused, & &1.summary)
    assert smells(doused) == ["You smell woodsmoke, faint, from the south-west."]
    assert "Mira Vale douses the kiln-house hearth." in summaries(watcher)

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

    walked = percepts(mira)
    assert smells(walked) == ["The smell of smoke fades."]
    assert Enum.any?(walked, &String.starts_with?(&1.summary || "", "You find The Source."))
    assert "Mira Vale leaves, heading upstream." in summaries(watcher)
    assert {:ok, %{here: %{name: "The Source"}}} = Session.look(mira)

    %{mira: mira, watcher: watcher}
  end

  # Mira lights the hearth and stands in its smoke for `steps` minutes.
  defp kindle(steps) do
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, _ref} = Session.act(mira, :kindle)
    Avwe.step(@world, steps)
    lit = percepts(mira)
    assert "You light the kiln-house hearth." in Enum.map(lit, & &1.summary)
    assert smells(lit) == ["You smell woodsmoke on the wind from the south-west."]
    mira
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

    # Nine intents of hers, and her session taking her at step 0.
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, records} = Store.records(store)
    advances = Enum.filter(records, &match?({:avwe, 2, {:advance, _entry}}, &1))
    assert length(records) == 66
    assert length(advances) == 57
    assert Enum.all?(advances, &match?({:avwe, 2, {:advance, %{steps: 1, dt: 60}}}, &1))
    assert submits_per_step(records) == [{0, 2}, {3, 1}, {4, 2}, {6, 2}, {31, 1}, {51, 1}]
    assert [{:avwe, 2, {:submit, 0, %{verb: :control, controller: :human}}} | _rest] = records
    assert Store.snapshots(store) == [0]

    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert rebuilt.step == 57
    assert Region.state_hash(rebuilt) == live_hash()

    # The fire, its smoke, Mira's nose and the warmed ground came back as
    # they are live, not only as a hash: the hearth doused with wood left,
    # the smoke still thinning behind her, her nose clear of it again.
    live = live_fire_state()
    assert %{@hearth => %{burning: false, out_at: out_at, fuel_kg: fuel}} = live.hearth
    assert out_at != nil and fuel > 7.9 and fuel < 8.0
    assert live.nose == %{"mira-vale" => %{smoke: :none}}
    assert length(live.puffs) == 12
    assert fire_state(rebuilt) == live
    :ok = Store.close(store)
  end

  test "a world started again from the same data dir carries on where it stopped", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    sessions = play()
    now = Avwe.now(@world)
    # Closing her session queues her release, journaled with the rest.
    :ok = Session.close(sessions.mira)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    :ok = start(tmp_dir)

    assert {:ok, %{step: 57}} = Avwe.snapshot(@world)
    assert Avwe.now(@world) == now
    assert live_hash() == hash

    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    assert {:ok, %{here: %{name: "The Source"}}} = Session.look(mira)

    # And it keeps going, and keeps logging, from there.
    assert {:ok, %{step: 58}} = Avwe.step(@world, 1)
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    # Her release from before the stop, her new session's control, the step.
    assert {:ok,
            [
              {:avwe, 2, {:submit, 57, %{verb: :release}}},
              {:avwe, 2, {:submit, 57, %{verb: :control}}},
              {:avwe, 2, {:advance, %{step: 57, steps: 1}}}
            ]} = Store.records_after(store, 57)

    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert Region.state_hash(rebuilt) == live_hash()
    :ok = Store.close(store)
  end

  test "a fire lit before a restart is still burning after it, with its smoke and its heat", %{
    tmp_dir: tmp_dir
  } do
    # Eight minutes of fire cross the snapshot at step 5, so the restart
    # resumes from a snapshot taken mid-fire plus three minutes of log.
    :ok = start(tmp_dir, snapshot_every: 5)
    mira = kindle(8)
    before = live_fire_state()
    assert %{@hearth => %{burning: true, lit_at: lit_at}} = before.hearth
    assert before.nose == %{"mira-vale" => %{smoke: :clear}}
    assert length(before.puffs) == 32
    :ok = Session.close(mira)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    :ok = start(tmp_dir, snapshot_every: 5)
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 5]
    :ok = Store.close(store)
    assert live_hash() == hash
    assert live_fire_state() == before

    # And the fire burns on for her: lit when it was, still smoking.
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")

    assert {:ok, %{hearth: %{id: @hearth, burning: true}, smoke: %{level: :clear}}} =
             Session.look(mira)

    Avwe.step(@world, 1)
    assert %{@hearth => %{burning: true, lit_at: ^lit_at}} = live_fire_state().hearth
    assert length(live_fire_state().puffs) == 36
  end

  test "a fire restarted exactly at a snapshot, with no log after it, keeps its smoke and nose",
       %{tmp_dir: tmp_dir} do
    # Nothing is replayed here, so whatever the snapshot drops stays dropped:
    # the body's nose and the smoke's last step must be in the snapshot itself.
    :ok = start(tmp_dir, snapshot_every: 5)
    mira = kindle(5)
    before = live_fire_state()
    assert before.nose == %{"mira-vale" => %{smoke: :clear}}
    assert {:ok, %{fields: %{smoke: %{last_step: %{emitted_g: emitted}}}}} = Avwe.snapshot(@world)
    assert emitted > 0
    :ok = Session.close(mira)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    # Nothing is replayed but her release, which touches none of that.
    :ok = start(tmp_dir, snapshot_every: 5)
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 5]
    assert {:ok, [{:avwe, 2, {:submit, 5, %{verb: :release}}}]} = Store.records_after(store, 5)
    :ok = Store.close(store)
    assert live_hash() == hash
    assert live_fire_state() == before

    assert {:ok, %{fields: %{smoke: %{last_step: %{emitted_g: ^emitted}}}}} =
             Avwe.snapshot(@world)
  end

  test "a crashed region comes back as it was after its last advance", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    sessions = play()
    hash = live_hash()

    crash_region()

    assert live_hash() == hash
    assert {:ok, %{step: 57}} = Avwe.snapshot(@world)

    {:ok, _ref} = Session.act(sessions.mira, :say, params: %{text: "Still here."})
    Avwe.step(@world, 1)
    assert [%{outcome: :success}] = results(sessions.mira)
    assert ~s(Mira Vale says, "Still here.") in summaries(sessions.watcher)
  end

  test "a region that crashes mid-fire comes back with the fire, its smoke and its heat", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    mira = kindle(3)
    before = live_fire_state()
    assert %{@hearth => %{burning: true}} = before.hearth
    assert before.nose == %{"mira-vale" => %{smoke: :clear}}
    assert length(before.puffs) == 12
    hash = live_hash()

    crash_region()

    assert live_hash() == hash
    assert live_fire_state() == before

    # The fire is hers to put out, as it was.
    {:ok, douse} = Session.act(mira, :douse)
    Avwe.step(@world, 1)
    assert [%{intent: ^douse, outcome: :success}] = results(mira)
    assert %{@hearth => %{burning: false}} = live_fire_state().hearth
  end

  test "an intent accepted before a crash still gets its one result", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
    {:ok, ref} = Session.act(mira, :say, params: %{text: "Before the crash."})

    crash_region()

    assert [
             {:avwe, 2, {:submit, 0, %{verb: :control, seq: 0}}},
             {:avwe, 2, {:submit, 0, %{ref: ^ref, seq: 1}}}
           ] = records(tmp_dir)

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
    assert {:ok, %Region{step: 57}} = Store.rebuild(store)
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

    # Put back, it picks up the sky where the world is (06:05): a system added
    # at restart is prepared for the saved time, so the light is right at once.
    :ok = start(tmp_dir, snapshot_every: 100)
    assert {:ok, %{step: 125}} = Avwe.snapshot(@world)
    assert light() > 0.0
  end

  test "a rules change is snapshotted at once, so a crash before the next snapshot replays under the new rules",
       %{tmp_dir: tmp_dir} do
    # Two hours from 04:00 under the usual rules, logged, no snapshot but step 0.
    :ok = start(tmp_dir, snapshot_every: 1_000)
    Avwe.step(@world, 100)
    assert light() == 0.0
    :ok = Avwe.stop_world(@world)

    # Restarted without any systems, and run past 06:00 (step 120): without
    # Daylight the sun does not rise.
    :ok = start(tmp_dir, snapshot_every: 1_000, systems: [])
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert Store.snapshots(store) == [0, 100]
    assert {:ok, %Region{step: 100, systems: []}} = Store.latest_snapshot(store)
    Avwe.step(@world, 30)
    assert light() == 0.0
    hash = live_hash()

    # The crash replays steps 100 to 130 from the snapshot the restart wrote,
    # under the new (empty) rules: still no sunrise, the same state. Had it
    # replayed from the step-0 snapshot, Daylight would have raised the sun.
    crash_region()

    assert {:ok, %{step: 130}} = Avwe.snapshot(@world)
    assert light() == 0.0
    assert live_hash() == hash
    assert {:ok, rebuilt} = Store.rebuild(store)
    assert rebuilt.systems == []
    assert Region.state_hash(rebuilt) == hash
    :ok = Store.close(store)
  end

  test "the saved seed is kept over the one the world is restarted with", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    Avwe.step(@world, 5)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    log = capture_log(fn -> :ok = start(tmp_dir, seed: 12_345) end)

    assert log =~ "ignoring :seed 12345; the world's seed is"
    assert log =~ "; delete #{store_dir(tmp_dir)} to start over"
    assert live_hash() == hash
  end

  test "the saved climate, hearths, miracles and characters are kept over the ones the world is restarted with",
       %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    Avwe.step(@world, 5)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    [town, lodge] = ember_reach_opts()[:hearths]
    [source_fails, last_coal] = ember_reach_opts()[:miracles]

    log =
      capture_log(fn ->
        :ok =
          start(tmp_dir,
            climate: [wind: [from: "north", m_s: 1.0]],
            hearths: [Keyword.merge(town, fuel_kg: 20.0, power_w: 6_000.0), lodge],
            miracles: [source_fails, Keyword.put(last_coal, :heat_w, 900.0)],
            characters: ["mira-vale": [norms: [], routine: [[at: "05:00", do: {:rest}]]]]
          )
      end)

    # Map keys print in no fixed order, so each line is matched by its parts.
    delete = "; delete #{store_dir(tmp_dir)} to start over"
    [climate] = lines(log, "ignoring :climate")

    assert climate =~
             ~r/ignoring :climate %\{(from: "north", m_s: 1\.0|m_s: 1\.0, from: "north")\}; /

    assert climate =~
             ~r/the world's wind is %\{(from: "south-west", m_s: 0\.2|m_s: 0\.2, from: "south-west")\}/

    assert String.ends_with?(climate, delete)

    [hearths] = lines(log, "ignoring :hearths")

    [wanted, kept] =
      hearths |> String.split("; the world's hearths are ") |> Enum.map(&hearth_values/1)

    assert wanted == %{"lodge-hearth" => [12.0, 5000.0], "town-hearth" => [20.0, 6000.0]}
    assert kept == %{"lodge-hearth" => [12.0, 5000.0], "town-hearth" => [8.0, 5000.0]}
    assert String.ends_with?(hearths, delete)

    [miracles] = lines(log, "ignoring :miracles")
    [wanted, kept] = String.split(miracles, "; the world's miracles are ")
    assert wanted =~ ~r/"the-last-coal" => %\{[^}]*heat_w: 900\.0/
    assert kept =~ ~r/"the-last-coal" => %\{[^}]*heat_w: 800\.0/
    assert wanted =~ ~s("the-source-fails" => %{) and wanted =~ "kind: :event"
    assert kept =~ ~s("the-source-fails" => %{) and kept =~ "set: %{flow_m3_s: 0.0}"
    assert String.ends_with?(miracles, delete)
    refute log =~ "applied_at"

    [characters] = lines(log, "ignoring :characters")
    [wanted, kept] = String.split(characters, "; the world's characters are ")
    assert wanted =~ ~r/"mira-vale" => %\{[^}]*norms: \[\]/ and wanted =~ "at: 18000"
    assert kept =~ ~r/"mira-vale" => %\{[^}]*norms: \[:invited_fire\]/ and kept =~ "at: 16200"
    assert String.ends_with?(characters, delete)
    refute log =~ "ignoring :seed"
    assert live_hash() == hash
    assert {:ok, %{env: %{wind: %{from: "south-west", m_s: 0.2}}}} = Avwe.snapshot(@world)
  end

  test "a world restarted as it was configured gets no warning, even once a hearth has burned", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    _mira = kindle(3)
    assert %{@hearth => %{fuel_kg: fuel}} = live_fire_state().hearth
    assert fuel < 8.0
    :ok = Avwe.stop_world(@world)

    log = capture_log(fn -> :ok = start(tmp_dir) end)

    refute log =~ "ignoring"
  end

  test "a snapshot this build cannot read stops the world from starting, naming it", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir)
    Avwe.step(@world, 5)
    :ok = Avwe.stop_world(@world)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, region} = Store.first_snapshot(store)
    :ok = Store.close(store)
    path = Path.join([store_dir(tmp_dir), "0-0", "snap-0000000000.bin"])
    File.write!(path, :erlang.term_to_binary({:avwe_snapshot, 2, region}))

    log =
      capture_log(fn ->
        assert {:error,
                {:shutdown,
                 {:failed_to_start_child, _child,
                  {:store, {:unknown_snapshot, ^path, {:avwe_snapshot, 2}}}}}} =
                 Avwe.start_world(@world, ember_reach_opts(data_dir: tmp_dir))
      end)

    assert log =~
             "no snapshot this build can read; #{path} is tagged {:avwe_snapshot, 2} " <>
               "and this build reads {:avwe_snapshot, 1}. " <>
               "Delete the world folder #{store_dir(tmp_dir)} to start over."

    assert Avwe.World.whereis(@world) == nil
  end

  test "a newest snapshot of an unknown version is skipped for an older one on restart", %{
    tmp_dir: tmp_dir
  } do
    :ok = start(tmp_dir, snapshot_every: 10)
    Avwe.step(@world, 25)
    hash = live_hash()
    :ok = Avwe.stop_world(@world)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, region} = Store.latest_snapshot(store)
    :ok = Store.close(store)
    newest = Path.join([store_dir(tmp_dir), "0-0", "snap-0000000020.bin"])
    File.write!(newest, :erlang.term_to_binary({:avwe_snapshot, 2, region}))

    log = capture_log(fn -> :ok = start(tmp_dir, snapshot_every: 10) end)

    assert log =~ "Skipping snapshot #{newest}"
    assert {:ok, %{step: 25}} = Avwe.snapshot(@world)
    assert live_hash() == hash
  end

  test "a world with no data dir writes nothing", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir, data_dir: nil)
    _sessions = play()

    assert File.ls!(tmp_dir) == []
  end

  describe "autopilot" do
    defp mira_action do
      {:ok, snapshot} = Avwe.snapshot(@world)
      get_in(snapshot.components, [:action, "mira-vale"])
    end

    test "a day on Mira's own replays exactly, and leaves nothing of hers in the journal", %{
      tmp_dir: tmp_dir
    } do
      :ok = start(tmp_dir, snapshot_every: 600)
      {:ok, watcher} = Avwe.connect(@world)
      Avwe.step(@world, 1440)

      seen = summaries(watcher)
      assert "Mira Vale leaves, heading toward The Dry Bend." in seen
      assert "Mira Vale arrives at Ashwarden Lodge." in seen

      # Autopilot's intents never pass through the journal: a day of them
      # is 1440 advances and no submit at all.
      records = records(tmp_dir)
      assert length(records) == 1440
      refute Enum.any?(records, &match?({:avwe, 2, {:submit, _step, _intent}}, &1))

      {:ok, store} = Store.open(store_dir(tmp_dir), @region)
      assert Store.snapshots(store) == [0, 600, 1200]
      assert {:ok, from_start} = Store.rebuild_from_start(store)
      assert {:ok, from_midday} = Store.rebuild(store)
      :ok = Store.close(store)
      assert from_start.step == 1440
      assert Region.state_hash(from_start) == live_hash()
      assert Region.state_hash(from_midday) == live_hash()

      # When someone does take her, the journal holds just that.
      {:ok, mira} = Avwe.connect(@world, body: "mira-vale")
      :ok = Session.close(mira)

      assert [
               {:avwe, 2, {:submit, 1440, %{verb: :control, controller: :human}}},
               {:avwe, 2, {:submit, 1440, %{verb: :release, controller: :human}}}
             ] = Enum.drop(records(tmp_dir), 1440)
    end

    test "a restart mid-journey resumes the journey", %{tmp_dir: tmp_dir} do
      # She sets off at 04:30 (step 30, a snapshot step): the intent she
      # decided on in step 29 is pending in that snapshot, and must be.
      :ok = start(tmp_dir, snapshot_every: 5)

      eventually(
        fn ->
          Avwe.step(@world, 1)
          match?(%{verb: :go, target: "the-dry-bend"}, mira_action())
        end,
        10_000
      )

      Avwe.step(@world, 2)
      hash = live_hash()
      assert {:ok, %{step: step}} = Avwe.snapshot(@world)
      assert step > 30
      :ok = Avwe.stop_world(@world)

      {:ok, store} = Store.open(store_dir(tmp_dir), @region)
      assert 30 in Store.snapshots(store)
      {:ok, records} = Store.records(store)
      refute Enum.any?(records, &match?({:avwe, 2, {:submit, _step, _intent}}, &1))

      assert {:ok,
              %Region{step: 30, inbox: [%{ref: "auto-mira-vale-29", controller: :autopilot}]}} =
               Store.latest_snapshot(store)

      :ok = Store.close(store)

      :ok = start(tmp_dir, snapshot_every: 5)
      assert live_hash() == hash
      assert %{verb: :go, target: "the-dry-bend", ref: "auto-mira-vale-29"} = mira_action()

      {:ok, watcher} = Avwe.connect(@world)
      assert {:ok, %{bodies: [%{going_to: "The Dry Bend"}]}} = Session.look(watcher)
      Avwe.step(@world, 12)
      assert "Mira Vale arrives at The Dry Bend." in summaries(watcher)

      {:ok, store} = Store.open(store_dir(tmp_dir), @region)
      assert {:ok, rebuilt} = Store.rebuild_from_start(store)
      assert Region.state_hash(rebuilt) == live_hash()
      :ok = Store.close(store)
    end
  end
end
