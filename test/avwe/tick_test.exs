defmodule Avwe.TickTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Tick}

  @six_am 6 * 3_600

  defp tick(time, dt), do: %Tick{step: 0, time: time, dt: dt, seed: 1, region: {0, 0}}

  describe "crossed?/3" do
    test "a step that ends exactly at the moment reaches it" do
      assert Tick.crossed?(
               tick(Calendar.at(813, hour: 5, minute: 59), 60),
               Calendar.day(),
               @six_am
             )
    end

    test "a step that starts exactly at the moment doesn't count it again" do
      refute Tick.crossed?(tick(Calendar.at(813, hour: 6), 60), Calendar.day(), @six_am)
    end

    test "a step entirely before or after the moment doesn't reach it" do
      refute Tick.crossed?(tick(Calendar.at(813, hour: 4), 60), Calendar.day(), @six_am)
      refute Tick.crossed?(tick(Calendar.at(813, hour: 7), 60), Calendar.day(), @six_am)
    end

    test "a step longer than the interval always reaches it" do
      assert Tick.crossed?(
               tick(Calendar.at(813, hour: 7), 2 * Calendar.day()),
               Calendar.day(),
               @six_am
             )
    end
  end

  test "last_occurrence/3 finds the moment inside the step" do
    tick = tick(Calendar.at(813, day: 3, hour: 5, minute: 30), Calendar.hour())

    assert Tick.last_occurrence(tick, Calendar.day(), @six_am) ==
             Calendar.at(813, day: 3, hour: 6)
  end

  test "rng/2 gives each system its own repeatable stream" do
    tick = tick(1_000, 60)

    draw = fn system ->
      tick |> Tick.rng(system) |> then(&:rand.uniform_s(1_000_000, &1)) |> elem(0)
    end

    assert draw.(:a) == draw.(:a)
    refute draw.(:a) == draw.(:b)
  end
end
