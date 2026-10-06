defmodule Avwe.IntegrationTest do
  @moduledoc """
  The heat, fire and smoke budgets with every system running together, as
  the Ember Reach runs in production: the unit properties check each system
  alone; this one checks that they still close when a body lights a fire, the
  river fails and the weather turns, at any step length.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Intent, Region}
  alias Avwe.Systems.Heat
  alias Avwe.Test.Ember

  @mira "mira-vale"
  @coal_w 800.0
  @f_ground 0.3
  @heat_lines [
    :sun_mj,
    :air_in_mj,
    :air_out_mj,
    :sky_in_mj,
    :sky_out_mj,
    :river_in_mj,
    :river_out_mj,
    :hearths_mj,
    :miracles_mj
  ]
  @smoke_lines [:emitted_g, :survived_g, :decayed_g, :dropped_g, :left_g]

  defp heat(region), do: region.fields.heat
  defp smoke(region), do: region.fields.smoke

  defp smoke_mass(region),
    do: region |> smoke() |> Map.fetch!(:puffs) |> Enum.map(& &1.g) |> Enum.sum()

  defp hearths(region) do
    for id <- Region.with_components(region, [:hearth, :position]),
        do: {id, Region.get(region, id, :hearth)}
  end

  # The exchange lines plus the energy of any cell activated this step.
  defp lines_sum(b) do
    b.activated_mj + b.sun_mj + b.air_in_mj - b.air_out_mj + b.sky_in_mj - b.sky_out_mj +
      b.river_in_mj - b.river_out_mj + b.hearths_mj + b.miracles_mj
  end

  defp assert_heat(before, after_step, dt) do
    b = heat(after_step).last_step

    assert b.dt == dt
    assert is_float(b.activated_mj)
    assert_in_delta b.delta_storage_mj, lines_sum(b), 1.0e-8
    assert_in_delta b.storage_after_mj - b.storage_before_mj, b.delta_storage_mj, 1.0e-8
    assert_in_delta b.storage_before_mj, Heat.stored_mj(heat(before)), 1.0e-8
    assert_in_delta b.storage_after_mj, Heat.stored_mj(heat(after_step)), 1.0e-8

    for line <- @heat_lines do
      value = Map.fetch!(b, line)
      assert is_float(value) and value >= 0.0, "#{line} is #{inspect(value)}"
    end

    ordinary_j =
      for {_id, %{last_step: %{miracle?: false, heat_j: heat_j}}} <- hearths(after_step),
          reduce: 0.0,
          do: (sum -> sum + heat_j)

    assert_in_delta b.hearths_mj, @f_ground * ordinary_j / 1.0e6, 1.0e-9
    assert_in_delta b.miracles_mj, @f_ground * @coal_w * dt / 1.0e6, 1.0e-9
  end

  defp assert_smoke(before, after_step) do
    b = smoke(after_step).last_step

    emitted =
      hearths(after_step) |> Enum.map(fn {_id, h} -> h.last_step.smoke_g end) |> Enum.sum()

    assert_in_delta b.storage_before_g, smoke_mass(before), 1.0e-9
    assert_in_delta b.storage_after_g, smoke_mass(after_step), 1.0e-9

    assert_in_delta b.storage_after_g - b.storage_before_g,
                    b.emitted_g - b.decayed_g - b.dropped_g - b.left_g,
                    1.0e-9

    assert_in_delta b.emitted_g, emitted, 1.0e-9

    for line <- @smoke_lines do
      value = Map.fetch!(b, line)
      assert is_float(value) and value >= 0.0, "#{line} is #{inspect(value)}"
    end
  end

  defp assert_hearths(before, after_step) do
    fuel_before = Map.new(hearths(before))

    for {id, hearth} <- hearths(after_step), step = hearth.last_step do
      assert step.heat_j == step.ground_j + step.vented_j
      assert step.burned_kg == fuel_before[id].fuel_kg - hearth.fuel_kg
      assert step.smoke_g == 10 * step.burned_kg
    end
  end

  property "every budget closes at any step length with every system running, fire lit or not" do
    check all steps <-
                list_of(member_of([60, 600, 3_600, 21_600, 86_400]),
                  min_length: 1,
                  max_length: 8
                ),
              minutes_before <- integer(-240..240),
              kindle? <- boolean(),
              max_runs: 20 do
      # Mira is played, so the only fire is the one this run lights.
      start =
        {812, day: 200, hour: 15, minute: -minutes_before}
        |> Ember.region()
        |> Ember.controlled()

      start =
        if kindle?,
          do: Region.submit(start, Intent.new(@mira, :kindle, ref: "kindle")),
          else: start

      # The random steps, then always one more minute: a step the smoke left
      # by the last one has to decay through, so a smoke that keeps its mass
      # while booking decay is caught even when the list is a single step.
      finish =
        Enum.reduce(steps ++ [60], start, fn dt, before ->
          after_step = Region.advance(before, 1, dt: dt)
          assert_heat(before, after_step, dt)
          assert_smoke(before, after_step)
          assert_hearths(before, after_step)
          after_step
        end)

      town = Region.get(finish, "town-hearth", :hearth)
      assert town.lit_at == if(kindle?, do: start.time, else: nil)
      assert town.burning == (kindle? and town.fuel_kg > 0)
    end
  end
end
