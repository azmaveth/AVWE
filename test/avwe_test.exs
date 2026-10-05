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
    assert_received {:avwe_events, @world, [%Event{type: :sunrise, time: ^sunrise}], view}
    assert view.time == sunrise
  end

  test "the same world can't be started twice" do
    assert {:error, {:already_started, _pid}} =
             Avwe.start_world(@world, quire: Fixtures.ember_reach())
  end

  test "a world without a Quire folder doesn't start" do
    assert {:error, :no_quire_path} = Avwe.start_world(:nowhere)
  end
end
