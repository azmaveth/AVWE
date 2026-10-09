defmodule Avwe.InputTest do
  @moduledoc """
  The kernel's inputs (`Avwe.Input`), with an input made for the test
  (`Avwe.Test.Poke`) and no agent layer: how a region takes them in, in what
  order it applies them, and how the journal and a snapshot treat them.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Event, Region, Store}
  alias Avwe.Test.Poke

  @moduletag :tmp_dir

  defp region, do: Region.new(id: {0, 0}, seed: 1)

  defp applied(region) do
    {events, region} = region |> Region.advance(1) |> Region.drain_events()
    {region, for(%Event{type: :poked, data: data} <- events, do: {data.group, data.seq})}
  end

  describe "a region's inbox" do
    test "numbers each input as it takes it in, and keeps them in the order submitted" do
      region =
        region()
        |> Region.submit(Poke.new(:a, 1))
        |> Region.submit(Poke.new(:b, 2))

      assert Enum.map(Region.pending(region), &{&1.key, &1.seq}) == [a: 0, b: 1]
      assert region.next_seq == 2
    end

    test "applies them sorted by their key and then their number" do
      region =
        region()
        |> Region.submit(Poke.new(:x, :first_of_two, group: 2))
        |> Region.submit(Poke.new(:x, :first_of_one, group: 1))
        |> Region.submit(Poke.new(:x, :second_of_two, group: 2))
        |> Region.submit(Poke.new(:x, :second_of_one, group: 1))

      {region, order} = applied(region)

      assert order == [{1, 1}, {1, 3}, {2, 0}, {2, 2}]
      assert region.env.x == :second_of_two
      assert Region.pending(region) == []
    end

    test "applies what it was given at the start of the next step and not before" do
      region = Region.submit(region(), Poke.new(:x, 1))

      refute Map.has_key?(region.env, :x)
      assert {%Region{env: %{x: 1}}, [{0, 0}]} = applied(region)
    end

    test "many steps at once are the same as one at a time, inputs included" do
      start =
        region() |> Region.submit(Poke.new(:x, 1)) |> Region.submit(Poke.new(:y, 2, group: 1))

      one_by_one = Enum.reduce(1..5, start, fn _n, acc -> Region.advance(acc, 1) end)

      assert Region.state_hash(Region.advance(start, 5)) == Region.state_hash(one_by_one)
    end
  end

  describe "the journal" do
    setup %{tmp_dir: dir} do
      {:ok, store} = Store.open(dir, {0, 0}, owner: true)
      on_exit(fn -> Store.close(store) end)
      %{store: store}
    end

    defp submit(store, region, poke) do
      region = Region.submit(region, poke)

      :ok =
        Store.append(store, Store.submit_record(region.step, List.last(Region.pending(region))))

      region
    end

    test "records inputs it does not look inside, and replays them to the same state", %{
      store: store
    } do
      start = region()
      :ok = Store.snapshot(store, start)

      live =
        start
        |> then(&submit(store, &1, Poke.new(:a, 1, group: :late)))
        |> then(&submit(store, &1, Poke.new(:b, 2, group: :early)))
        |> advance(store, 2)
        |> then(&submit(store, &1, Poke.new(:a, 3)))
        |> advance(store, 1)

      assert {:ok, rebuilt} = Store.rebuild(store)
      assert Region.state_hash(rebuilt) == Region.state_hash(live)
      assert rebuilt.env == %{a: 3, b: 2}

      assert {:ok, from_start} = Store.rebuild_from_start(store)
      assert Region.state_hash(from_start) == Region.state_hash(live)
    end

    defp advance(region, store, steps) do
      before = region
      {events, region} = before |> Region.advance(steps) |> Region.drain_events()
      :ok = Store.append(store, Store.advance_record(before, steps, before.dt, events))
      region
    end

    test "a snapshot keeps the inputs a system made and gives back the numbers of the rest", %{
      store: store
    } do
      region =
        region()
        |> Region.submit(Poke.new(:made, 1, derived: true))
        |> Region.submit(Poke.new(:sent, 2))

      :ok = Store.snapshot(store, region)
      assert {:ok, saved} = Store.latest_snapshot(store)

      assert Enum.map(saved.inbox, & &1.key) == [:made]
      assert saved.next_seq == 1
    end

    test "a replay that finds the numbers have drifted says so", %{store: store} do
      :ok = Store.snapshot(store, region())
      poked = Poke.new(:a, 1, seq: 7)
      :ok = Store.append(store, Store.submit_record(0, poked))

      assert Store.rebuild(store) == {:error, {:seq_mismatch, 0, 7, 0}}
    end
  end
end
