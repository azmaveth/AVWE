defmodule Avwe.E2E.GuestsPersistenceTest do
  @moduledoc """
  A guest through the store: Lantern Hollow persisting itself to a temporary
  data dir. An arrival is an intent like any other, journaled once the region
  has agreed to it, so replaying the log reproduces the world with its guest
  in it, and a world started again from disk keeps the guest, held by nobody,
  whatever settings for guests it is started with.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import ExUnit.CaptureLog

  alias Avwe.{Region, RegionServer, Session, Store}

  @moduletag :tmp_dir
  @world :hollow_guests_persist
  @region {0, 0}
  @guests [arrival: "hollow-green", max: 2]
  @tomas [name: "Tomas Reed", backstory: "A salvage diver from Willow Docks."]

  defp start(tmp_dir, guests \\ @guests) do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        data_dir: tmp_dir,
        guests: guests
      )

    :ok
  end

  defp records(tmp_dir) do
    {:ok, store} = Store.open(Path.join(tmp_dir, to_string(@world)), @region)
    {:ok, records} = Store.records(store)
    {store, records}
  end

  defp live_hash do
    {:ok, hash} = RegionServer.state_hash(@world, @region)
    hash
  end

  # Tomas arrives, writes in his notebook, walks to the pond, and goes.
  defp play do
    {:ok, tomas} = Avwe.connect(@world, guest: @tomas, controller: :mcp)
    Avwe.step(@world, 1)
    :ok = Session.await_arrival(tomas, 1_000)

    {:ok, _ref} = Session.act(tomas, :write, params: %{text: "The well is deep."})
    {:ok, _ref} = Session.act(tomas, :go, target: "mill-pond")
    Avwe.step(@world, 40)
    Session.close(tomas)
    Avwe.step(@world, 2)
    assert eventually(fn -> lease_free?() end)
    :ok
  end

  defp lease_free?, do: Registry.lookup(Avwe.Registry, {:lease, @world, "guest-tomas-reed"}) == []

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> Avwe.stop_world(@world) end)
    %{tmp_dir: tmp_dir}
  end

  test "replaying the log reproduces the world with its guest in it", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    play()

    {store, records} = records(tmp_dir)

    # Journaled as intents: the arrival, then the guest's control, and what it did.
    assert [
             {:avwe, 2, {:submit, 0, %{verb: :arrive, body: "guest-tomas-reed"} = arrival}}
             | _rest
           ] =
             Enum.filter(records, &match?({:avwe, 2, {:submit, _step, _intent}}, &1))

    assert arrival.params.name == "Tomas Reed"

    assert {:ok, rebuilt} = Store.rebuild_from_start(store)
    assert Region.state_hash(rebuilt) == live_hash()

    assert %{backstory: "A salvage diver from Willow Docks."} =
             Region.get(rebuilt, "guest-tomas-reed", :guest)

    assert [%{text: "The well is deep."}] =
             Region.get(rebuilt, "guest-tomas-reed-notebook", :notebook).pages

    Store.close(store)
  end

  test "an arrival the region refuses is never journaled", %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)

    assert {:error, :name_taken} = Avwe.connect(@world, guest: [name: "Wren"], controller: :mcp)
    assert {:error, :invalid_name} = Avwe.connect(@world, guest: [name: "x"], controller: :mcp)

    {store, records} = records(tmp_dir)
    refute Enum.any?(records, &match?({:avwe, 2, {:submit, _step, %{verb: :arrive}}}, &1))
    Store.close(store)
  end

  test "a world started again keeps the guest, held by nobody, and takes the guests it is told to",
       %{tmp_dir: tmp_dir} do
    :ok = start(tmp_dir)
    play()
    live = live_hash()
    Avwe.stop_world(@world)

    # Started with no settings for guests, it takes no more, but keeps this
    # one, and has no complaint of the characters it was not told of: a guest
    # arrived, and was never declared.
    log = capture_log(fn -> :ok = start(tmp_dir, nil) end)
    refute log =~ "ignoring"
    assert live_hash() == live

    assert {:error, :no_guests} =
             Avwe.connect(@world, guest: [name: "Ines Cole"], controller: :mcp)

    assert {:ok, bodies} = Avwe.bodies(@world)

    assert %{guest: true, taken: false, controller: :autopilot, name: "Tomas Reed"} =
             Enum.find(bodies, &(&1.id == "guest-tomas-reed"))

    {:ok, again} = Avwe.connect(@world, body: "guest-tomas-reed", controller: :mcp)
    {:ok, ref} = Session.act(again, :read)
    Avwe.step(@world, 1)

    assert %{data: %{pages: [%{text: "The well is deep."}]}} =
             again |> percepts() |> Enum.find(&(&1.intent == ref))

    Avwe.stop_world(@world)

    # Started with room for one guest, it is full.
    :ok = start(tmp_dir, arrival: "hollow-green", max: 1)
    assert {:error, :full} = Avwe.connect(@world, guest: [name: "Ines Cole"], controller: :mcp)
  end
end
