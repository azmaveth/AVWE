defmodule Avwe.Systems.SmokeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Event, Intent, Region}
  alias Avwe.Systems.{Fire, Miracles, Smoke}
  alias Avwe.Test.Ember

  @systems [Miracles, Fire, Smoke]
  @lodge "lodge-hearth"
  @town "town-hearth"
  @mira "mira-vale"

  setup_all do
    %{region: Ember.region({813, day: 220, hour: 10}, systems: @systems)}
  end

  defp light(region, id) do
    hearth = Region.get(region, id, :hearth)
    Region.put_component(region, id, :hearth, %{hearth | burning: true, lit_at: region.time})
  end

  defp wind(region, from, m_s), do: Region.put_env(region, :wind, %{from: from, m_s: m_s})

  defp smoke(region), do: region.fields.smoke

  defp mass(region), do: region |> smoke() |> Map.fetch!(:puffs) |> Enum.map(& &1.g) |> Enum.sum()

  defp centre(region) do
    puffs = smoke(region).puffs
    total = Enum.sum(Enum.map(puffs, & &1.g))

    {Enum.sum(Enum.map(puffs, &(&1.g * &1.x))) / total,
     Enum.sum(Enum.map(puffs, &(&1.g * &1.y))) / total}
  end

  defp hearth_smoke(region) do
    region
    |> Region.with_components([:hearth])
    |> Enum.map(&Region.get(region, &1, :hearth).last_step.smoke_g)
    |> Enum.sum()
  end

  defp body(region, id, cell) do
    Region.put_entity(region, id, %{body: %{species: nil}, position: cell, repr: %{name: id}})
  end

  defp submit(region, verb, opts) do
    ref = Keyword.get(opts, :ref, "mira-#{verb}")
    Region.submit(region, Intent.new(@mira, verb, Keyword.put(opts, :ref, ref)))
  end

  defp run(region, steps, dt \\ 60) do
    {events, region} = region |> Region.advance(steps, dt: dt) |> Region.drain_events()
    {region, events}
  end

  defp smelled(events, body),
    do: for(%Event{type: :smoke_smelled, entity: ^body, data: data} <- events, do: data)

  defp faded(events, body), do: for(%Event{type: :smoke_faded, entity: ^body} <- events, do: body)

  describe "conservation" do
    property "storage changes only by emitted − decayed − dropped − left", %{region: region} do
      lit = region |> light(@lodge) |> light(@town)

      check all dts <- list_of(member_of([60, 600, 3_600, 86_400]), min_length: 1, max_length: 8),
                max_runs: 25 do
        Enum.reduce(dts, lit, fn dt, acc ->
          before = mass(acc)
          {acc, _events} = run(acc, 1, dt)
          b = smoke(acc).last_step

          assert_in_delta b.storage_before_g, before, 1.0e-9
          assert_in_delta b.storage_after_g, mass(acc), 1.0e-9

          assert_in_delta b.storage_after_g - b.storage_before_g,
                          b.emitted_g - b.decayed_g - b.dropped_g - b.left_g,
                          1.0e-9

          assert_in_delta b.emitted_g, hearth_smoke(acc), 1.0e-9
          assert b.survived_g <= b.emitted_g

          for {key, value} <-
                Map.take(b, [:emitted_g, :survived_g, :decayed_g, :dropped_g, :left_g]) do
            assert value >= 0, "#{key} is #{value}"
          end

          acc
        end)
      end
    end

    test "a cold world has no smoke and a zeroed budget", %{region: region} do
      {region, events} = run(region, 3)
      assert smoke(region).puffs == []
      assert smoke(region).last_step == Smoke.new().last_step

      assert events |> Enum.map(& &1.type) |> Enum.filter(&(&1 in [:smoke_smelled, :smoke_faded])) ==
               []
    end
  end

  describe "stepping" do
    test "by the hour or by the minute leaves the same mass in the same place", %{region: region} do
      # A light wind, so an hour's plume from the lodge stays on the map.
      lit = region |> wind("north", 0.3) |> light(@lodge)

      {hourly, _events} = run(lit, 1, 3_600)
      {minutely, _events} = run(lit, 60, 60)

      assert [_one_puff] = smoke(hourly).puffs
      assert length(smoke(minutely).puffs) == 60
      assert_in_delta mass(hourly), mass(minutely), 1.0e-9

      {hx, hy} = centre(hourly)
      {mx, my} = centre(minutely)
      assert abs(hx - mx) < 0.5
      assert abs(hy - my) < 0.5

      # The plume is south of the lodge, where the wind took it.
      {_x, lodge_y} = Ember.places().lodge
      assert hy > lodge_y + 10
      assert_in_delta hx, elem(Ember.places().lodge, 0) + 0.5, 1.0e-9
    end

    test "puffs are sorted and bounded", %{region: region} do
      {region, _events} = region |> light(@lodge) |> run(300)
      puffs = smoke(region).puffs

      assert puffs == Enum.sort_by(puffs, &{&1.born, &1.x, &1.y})
      assert length(puffs) <= 76
    end
  end

  describe "smell" do
    setup %{region: region} do
      {x, y} = Ember.places().lodge

      region =
        region
        |> wind("north", 2.0)
        |> body("south", {x, y + 30})
        |> body("north", {x, y - 30})
        |> Region.put_component(@mira, :position, {x, y})

      %{region: region}
    end

    test "reaches a body downwind and never one upwind", %{region: region} do
      {region, events} = region |> submit(:kindle, target: @lodge) |> run(5)

      assert [%{level: level, from: "north"}] = smelled(events, "south")
      assert level in [:faint, :clear, :thick]
      assert Region.get(region, "south", :nose) == %{smoke: level}
      assert smelled(events, "north") == []

      {region, events} = run(region, 115)
      assert smelled(events, "north") == []
      assert Region.get(region, "north", :nose) == nil
      assert length(smoke(region).puffs) <= 76

      {region, events} = region |> submit(:douse, target: @lodge) |> run(20)
      assert ["south"] = faded(events, "south")
      assert Region.get(region, "south", :nose) == %{smoke: :none}

      {region, _events} = run(region, 120)
      assert smoke(region).puffs == []
    end
  end

  describe "the parts" do
    test "the wind carries smoke away from where it comes from" do
      assert {x, y} = Smoke.drift_cells(%{from: "north", m_s: 2.0}, 60)
      assert_in_delta x, 0.0, 1.0e-12
      assert_in_delta y, 12.0, 1.0e-12

      assert {x, y} = Smoke.drift_cells(%{from: "east", m_s: 1.0}, 10)
      assert_in_delta x, -1.0, 1.0e-12
      assert_in_delta y, 0.0, 1.0e-12

      assert {x, y} = Smoke.drift_cells(%{from: "south-west", m_s: 2.0}, 100)
      assert x > 0 and y < 0
      assert_in_delta x, -y, 1.0e-9
    end

    test "a fresh minute of a 5 kW hearth is thick at the hearth" do
      field = %{puffs: [%{x: 10.5, y: 10.5, g: 0.1875, born: 0.0}], last_step: nil}

      assert_in_delta Smoke.density_g_m2(field, {10, 10}, 0), 1.19e-3, 0.01e-3
      assert Smoke.level(Smoke.density_g_m2(field, {10, 10}, 0)) == :thick
      assert Smoke.density_g_m2(field, {10, 13}, 0) < Smoke.density_g_m2(field, {10, 11}, 0)
      assert Smoke.density_g_m2(%{puffs: []}, {10, 10}, 0) == 0.0
    end

    test "levels" do
      assert Smoke.level(0.0) == :none
      assert Smoke.level(9.0e-6) == :none
      assert Smoke.level(1.0e-5) == :faint
      assert Smoke.level(1.0e-4) == :clear
      assert Smoke.level(5.0e-3) == :thick
    end
  end
end
