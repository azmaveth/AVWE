defmodule Avwe.E2E.HooksTest do
  @moduledoc """
  End to end through the public API and the disk, with inputs and hooks made
  for the test and no agent layer (`hooks: []`, no systems): a region refuses an
  input before it is journaled, applies the ones it takes, and asks the layers
  above what a resumed region needs, accepting what they say as if it had
  come from outside.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0]

  alias Avwe.{Event, Region, RegionServer, Store}
  alias Avwe.Test.{Poke, PokeHooks}

  @moduletag :tmp_dir
  @world :hollow_hooks
  @region {0, 0}

  setup do
    Process.register(self(), :poke_hooks_probe)
    on_exit(fn -> Avwe.stop_world(@world) end)
    :ok
  end

  defp start(tmp_dir, hooks) do
    Avwe.start_world(@world,
      quire: lantern_hollow(),
      start: {1, hour: 12},
      data_dir: tmp_dir,
      systems: [],
      hooks: hooks
    )
  end

  defp env(key) do
    {:ok, %{env: env}} = Avwe.snapshot(@world)
    Map.get(env, key)
  end

  defp store_dir(tmp_dir), do: Path.join(tmp_dir, to_string(@world))

  test "a region takes an input it is given, applies it at the next step and tells those listening",
       %{tmp_dir: tmp_dir} do
    {:ok, _pid} = start(tmp_dir, [])
    {:ok, _} = Avwe.subscribe(@world)

    assert RegionServer.submit(@world, @region, Poke.new(:x, 1)) == :ok
    assert env(:x) == nil

    Avwe.step(@world, 1)

    assert env(:x) == 1
    assert_receive {:avwe_events, @world, [%Event{type: :poked, data: %{key: :x}}], _view}
  end

  test "a region refuses an input that says it would not be taken, and journals nothing of it",
       %{tmp_dir: tmp_dir} do
    {:ok, _pid} = start(tmp_dir, [])

    assert RegionServer.submit(@world, @region, Poke.new(:x, 1, refuse: :nope)) ==
             {:error, :nope}

    assert RegionServer.submit(@world, @region, Poke.new(:y, 2)) == :ok
    Avwe.step(@world, 1)
    :ok = Avwe.stop_world(@world)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, records} = Store.records(store)
    :ok = Store.close(store)

    submitted = for {:avwe, 2, {:submit, _step, %Poke{key: key}}} <- records, do: key
    assert submitted == [:y]
  end

  test "a region refuses an input that a system made, which is never journaled", %{
    tmp_dir: tmp_dir
  } do
    {:ok, _pid} = start(tmp_dir, [])

    assert RegionServer.submit(@world, @region, Poke.new(:z, 3, derived: true)) ==
             {:error, :derived_input}

    Avwe.step(@world, 2)
    assert env(:z) == nil
    :ok = Avwe.stop_world(@world)

    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    {:ok, records} = Store.records(store)
    :ok = Store.close(store)

    assert for({:avwe, 2, {:submit, _step, _input}} <- records, do: :submitted) == []

    # And the world comes back from what it kept.
    assert {:ok, _pid} = start(tmp_dir, [])
    assert {:ok, %{step: 2}} = Avwe.snapshot(@world)
  end

  test "a region that is started again asks its hooks, and accepts and journals what they say",
       %{tmp_dir: tmp_dir} do
    {:ok, _pid} = start(tmp_dir, [PokeHooks])
    assert_receive {:resumed, 0, %{world: @world, definition: nil}}
    refute_received {:reconfigured, _saved, _given, _context}

    Avwe.step(@world, 3)
    assert RegionServer.submit(@world, @region, Poke.new(:a, 1)) == :ok
    Avwe.step(@world, 1)
    :ok = Avwe.stop_world(@world)

    {:ok, _pid} = start(tmp_dir, [PokeHooks])

    # Told what differs between the saved region and the one it was given, and
    # what to submit; what it submitted waits for the next step.
    assert_receive {:reconfigured, 4, 0, %{world: @world, dir: dir}}
    assert dir == store_dir(tmp_dir)
    assert_receive {:resumed, 4, _context}
    assert env(:starts) == 1

    Avwe.step(@world, 1)
    assert env(:starts) == 2
    assert env(:a) == 1
    {:ok, live} = RegionServer.state_hash(@world, @region)
    :ok = Avwe.stop_world(@world)

    # The input the hook made was journaled like any other, so the history
    # replays to the same state.
    {:ok, store} = Store.open(store_dir(tmp_dir), @region)
    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    :ok = Store.close(store)

    assert Region.state_hash(rebuilt) == live
  end

  test "a world with no hooks asks nobody", %{tmp_dir: tmp_dir} do
    {:ok, _pid} = start(tmp_dir, [])
    Avwe.step(@world, 2)
    :ok = Avwe.stop_world(@world)

    {:ok, _pid} = start(tmp_dir, [])

    refute_received {:resumed, _step, _context}
    refute_received {:reconfigured, _saved, _given, _context}
    assert {:ok, %{step: 2}} = Avwe.snapshot(@world)
  end
end
