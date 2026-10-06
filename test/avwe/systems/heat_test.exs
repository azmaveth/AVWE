defmodule Avwe.Systems.HeatTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Calendar, Event, Region, Terrain}
  alias Avwe.Systems.{Daylight, Heat, Miracles, River, Weather}
  alias Avwe.Systems.Heat.Field
  alias Avwe.Test.{Ember, Fixtures}

  @systems [Daylight, Miracles, Weather, River, Heat]
  @hour Calendar.hour()
  @day Calendar.day()
  @hearth_w 5_000.0
  @coal_w 800.0
  @fuel_j_per_kg 16.0e6
  @f_ground 0.3
  @lines [
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
  # The source failing at 19:00 instead of 15:00, once the banks are steaming.
  @late_failure [
    id: "the-source-fails",
    at: {812, day: 200, hour: 19},
    target: "river-source",
    component: :spring,
    set: %{flow_m3_s: 0.0},
    cause: :unknown,
    note: "The Ember's source stops, four hours late."
  ]

  # Regions and hand-built hearths

  defp region(at, overrides \\ []),
    do: Ember.region(at, Keyword.merge([systems: @systems], overrides))

  defp field(region), do: region.fields.heat
  defp budget(region), do: field(region).last_step

  # A hearth as the fire system would leave it after a step of `dt`, so the
  # heat system can read its ground share (§6.1 of the spec).
  defp burning_step(dt, power_w, miracle?) do
    heat_j = power_w * dt
    burned = if miracle?, do: 0.0, else: power_w / @fuel_j_per_kg * dt

    %{
      burn_s: dt * 1.0,
      burned_kg: burned,
      heat_j: heat_j,
      ground_j: @f_ground * heat_j,
      vented_j: heat_j - @f_ground * heat_j,
      smoke_g: 10 * burned,
      miracle?: miracle?
    }
  end

  defp cold_step, do: burning_step(0, 0.0, false)

  defp with_hearth(region, id, cell, dt, opts \\ []) do
    burning = Keyword.get(opts, :burning, true)
    last_step = if burning, do: burning_step(dt, @hearth_w, false), else: cold_step()

    Region.put_entity(region, id, %{
      position: cell,
      repr: %{name: "the #{id}", description: nil},
      hearth: %{
        fuel_kg: 12.0,
        burning: burning,
        lit_at: if(burning, do: region.time, else: nil),
        out_at: nil,
        power_w: @hearth_w,
        low_kg: 1.0,
        last_step: last_step
      }
    })
  end

  defp with_coal(region, cell, dt) do
    Region.put_entity(region, "the-last-coal", %{
      position: cell,
      repr: %{name: "The Last Coal", description: nil},
      hearth: %{
        fuel_kg: 0.0,
        burning: true,
        lit_at: nil,
        out_at: nil,
        power_w: @coal_w,
        low_kg: 0.0,
        last_step: burning_step(dt, @coal_w, true)
      },
      miracle: %{
        kind: :standing,
        breaks: [:fuel, :dousing],
        heat_w: @coal_w,
        cause: :unknown,
        note: "Heat without fuel, declared."
      }
    })
  end

  # The town hearth and the Last Coal, each with a step of `dt` behind it.
  defp with_sources(region, dt) do
    region
    |> with_hearth("town-hearth", Ember.places().town, dt)
    |> with_coal(Ember.places().lodge, dt)
  end

  # A standing miracle exists from worldgen, so the field settles with it and
  # its cell is active from the start. Re-prepares every system.
  defp with_standing_sources(region, dt) do
    Region.prepare(%{with_sources(region, dt) | fields: %{}})
  end

  # Cells

  defp indices(field), do: 0..(tuple_size(field.static) - 1)//1
  defp temperatures(field), do: Enum.map(indices(field), &Heat.cell_c(field, &1))
  defp background_c(field, material), do: Heat.cell_c(field, field.index[{:background, material}])

  defp reach_near(region, place) do
    {index, _cell, _distance} = Terrain.nearest_channel(region.terrain, Ember.places()[place])
    Terrain.reach_of(region.terrain, index)
  end

  defp distance_to_channel(region, i) do
    {_index, _cell, d} =
      Terrain.nearest_channel(region.terrain, elem(field(region).static, i).cell)

    d
  end

  # A silt cell `d` cells from the channel on the banks of the reach nearest a place.
  defp bank_cell(region, place, d) do
    region
    |> field()
    |> Map.fetch!(:bank_cells)
    |> Map.fetch!(reach_near(region, place))
    |> Enum.find(&(abs(distance_to_channel(region, &1) - d) < 1.0e-6))
  end

  # A silt cell as far from the channel as silt goes, beside a reach that is
  # silent or, while the river runs, the least coupled a bank cell can be.
  defp dry_silt(region) do
    region
    |> field()
    |> indices()
    |> Enum.find(fn i ->
      static = elem(field(region).static, i)
      static.material == :silt and abs(distance_to_channel(region, i) - 6.0) < 1.0e-6
    end)
  end

  # An open stone cell: high ground, which the Ember Reach has only up near
  # the source and on the lodge's rise.
  defp stone_cell(region) do
    Enum.find(for(x <- 0..255//4, y <- 0..255//4, do: {x, y}), fn cell ->
      Terrain.ground(region.terrain, cell) == :stone and
        not Map.has_key?(field(region).index, cell)
    end)
  end

  defp open_grass(region) do
    {tx, ty} = Ember.places().town

    Enum.find(for(dx <- 5..40, do: {tx - dx, ty}), fn cell ->
      Terrain.ground(region.terrain, cell) == :grass and
        not Map.has_key?(field(region).index, cell)
    end)
  end

  defp max_difference(a, b) do
    Enum.max(Enum.zip_with(temperatures(field(a)), temperatures(field(b)), &abs(&1 - &2)))
  end

  # The exchange lines plus the energy of the cells activated this step: what
  # the storage change must equal.
  defp lines_sum(b) do
    b.activated_mj + b.sun_mj + b.air_in_mj - b.air_out_mj + b.sky_in_mj - b.sky_out_mj +
      b.river_in_mj - b.river_out_mj + b.hearths_mj + b.miracles_mj
  end

  defp events(region, type) do
    {events, _region} = Region.drain_events(region)
    for %Event{type: ^type} = event <- events, do: event
  end

  describe "conservation" do
    property "the budget closes at any step length, with a hearth and the Last Coal burning" do
      check all steps <-
                  list_of(member_of([60, 600, 3_600, 21_600, 86_400]),
                    min_length: 1,
                    max_length: 8
                  ),
                minutes_before <- integer(-240..240),
                max_runs: 25 do
        start =
          region({812, day: 200, hour: 15, minute: -minutes_before}) |> with_standing_sources(60)

        Enum.reduce(steps, start, fn dt, before ->
          before = with_sources(before, dt)
          stored_before = Heat.stored_mj(field(before))
          after_step = Region.advance(before, 1, dt: dt)
          b = budget(after_step)

          assert b.dt == dt
          # Every cell is active from the settle: nothing is activated here.
          assert b.activated_mj == 0.0
          # The spec allows 1e-6 MJ; the compensated sums close to under
          # 1e-8 (the bound is n·eps·max|E| ≈ 2.4e-9), and plain sums do not.
          assert_in_delta b.delta_storage_mj, lines_sum(b), 1.0e-8
          assert_in_delta b.storage_after_mj - b.storage_before_mj, b.delta_storage_mj, 1.0e-8
          assert_in_delta b.storage_before_mj, stored_before, 1.0e-6
          assert_in_delta b.storage_after_mj, Heat.stored_mj(field(after_step)), 1.0e-6

          for line <- @lines do
            value = Map.fetch!(b, line)
            assert is_float(value) and value >= 0.0, "#{line} is #{inspect(value)}"
          end

          assert_in_delta b.miracles_mj, @f_ground * @coal_w * dt / 1.0e6, 1.0e-9
          assert_in_delta b.hearths_mj, @f_ground * @hearth_w * dt / 1.0e6, 1.0e-9
          after_step
        end)
      end
    end

    test "the storage totals are compensated sums: a joule survives two ten-petajoule neighbours" do
      cap = Heat.materials()[:grass].cap_j_m2k * 100.0

      static = fn x ->
        %{
          cell: {x, 0},
          material: :grass,
          area_m2: 100.0,
          cap_j_k: cap,
          absorb_m2: 45.0,
          river: nil
        }
      end

      field = %Field{
        static: {static.(0), static.(1), static.(2)},
        index: %{{0, 0} => 0, {1, 0} => 1, {2, 0} => 2},
        energy: {1.0e16, 1.0, -1.0e16}
      }

      assert Heat.stored_mj(field) == 1.0e-6

      {_stepped, last_step} =
        Heat.step_field(field, %{air_c: 15.0, sky_c: 5.0, light: 0.0}, %{}, {}, 1)

      assert last_step.storage_before_mj == 1.0e-6
    end

    test "the river couples only while it flows" do
      night = region({812, day: 199, hour: 4}) |> Region.advance(1)
      assert budget(night).river_in_mj > 0

      dry = region({813, day: 220, hour: 4}) |> Region.advance(1)
      assert budget(dry).river_in_mj == 0.0
      assert budget(dry).river_out_mj == 0.0
    end
  end

  describe "a cell under constant forcing" do
    @forcing %{air_c: 20.0, sky_c: 10.0, light: 0.5}

    defp one_cell(material, t0_c, opts \\ []) do
      %{cap_j_m2k: cap, absorb: absorb} = Heat.materials()[material]
      area = Keyword.get(opts, :area_m2, 100.0)

      static = %{
        cell: {0, 0},
        material: material,
        area_m2: area,
        cap_j_k: cap * area,
        absorb_m2: absorb * area,
        river: Keyword.get(opts, :river)
      }

      %Field{static: {static}, index: %{{0, 0} => 0}, energy: {cap * area * (t0_c - 15.0)}}
    end

    # The equilibrium of a cell with no river, by hand.
    defp equilibrium(material, source_w, area) do
      %{absorb: absorb} = Heat.materials()[material]

      (15.0 * @forcing.air_c + 5.0 * @forcing.sky_c + 800.0 * absorb * @forcing.light +
         source_w / area) / 20.0
    end

    test "lands between its start and its equilibrium for any step, and on the exact solution" do
      for material <- [:grass, :silt, :stone],
          t0 <- [5.0, 40.0],
          dt <- [1, 60, 3_600, 86_400, 864_000] do
        field = one_cell(material, t0)
        source_j = @f_ground * @hearth_w * dt
        {stepped, last_step} = Heat.step_field(field, @forcing, %{0 => {source_j, 0.0}}, {}, dt)
        t1 = Heat.cell_c(stepped, 0)
        t_eq = equilibrium(material, @f_ground * @hearth_w, 100.0)

        assert t1 >= min(t0, t_eq) - 1.0e-9 and t1 <= max(t0, t_eq) + 1.0e-9
        assert is_float(t1)

        x = dt * 20.0 / Heat.materials()[material].cap_j_m2k
        exact = t_eq + (t0 - t_eq) * :math.exp(-x)
        assert_in_delta t1, exact, 1.0e-9

        assert_in_delta last_step.delta_storage_mj, lines_sum(last_step), 1.0e-9
        assert_in_delta last_step.hearths_mj, source_j / 1.0e6, 1.0e-9
      end
    end

    test "a flowing reach warms the cell and a silent one does not" do
      reaches = {%{silent: false, temp_c: 38.0, volume: 1.0}}
      field = one_cell(:silt, 20.0, river: {0, 31.2 * 100.0})

      {warmed, warmed_step} = Heat.step_field(field, @forcing, %{}, reaches, 3_600)

      {cut_off, cut_step} =
        Heat.step_field(
          field,
          @forcing,
          %{},
          put_elem(reaches, 0, %{silent: true, temp_c: 38.0}),
          3_600
        )

      assert Heat.cell_c(warmed, 0) > Heat.cell_c(cut_off, 0)
      assert warmed_step.river_in_mj > 0 and warmed_step.river_out_mj == 0.0
      assert cut_step.river_in_mj == 0.0 and cut_step.river_out_mj == 0.0
    end

    test "sixty minute steps equal one hour step, cell by cell" do
      start = region({812, day: 199, hour: 10})
      field = field(start)
      reaches = Region.get(start, River.id(), :river).reaches
      town = field.index[Ember.places().town]
      source = fn dt -> %{town => {@f_ground * @hearth_w * dt, 0.0}} end

      {fine, _} =
        Enum.reduce(1..60, {field, nil}, fn _, {f, _} ->
          Heat.step_field(f, @forcing, source.(60), reaches, 60)
        end)

      {coarse, _} = Heat.step_field(field, @forcing, source.(3_600), reaches, 3_600)

      assert_in_delta Heat.stored_mj(fine) / Heat.stored_mj(coarse), 1.0, 1.0e-9

      for i <- indices(field) do
        assert_in_delta Heat.cell_c(fine, i), Heat.cell_c(coarse, i), 1.0e-9
      end
    end
  end

  describe "boundedness" do
    test "sixty day-long steps then a day of minutes stay within 5 to 55 °C" do
      region = region({813, day: 220, hour: 4})

      days = Region.advance(region, 60, dt: @day)
      minutes = Region.advance(days, 1_440, dt: 60)

      for stepped <- [days, minutes], t <- temperatures(field(stepped)) do
        assert is_float(t)
        assert t >= 5.0 and t <= 55.0
      end
    end
  end

  describe "dt-consistency under the real day" do
    test "an hour of minutes matches one hour step, morning and evening, with the town hearth lit" do
      for hour <- [7, 19] do
        base = region({812, day: 200, hour: hour})
        town = Ember.places().town
        fine = base |> with_hearth("town-hearth", town, 60) |> Region.advance(60, dt: 60)
        coarse = base |> with_hearth("town-hearth", town, 3_600) |> Region.advance(1, dt: 3_600)

        assert max_difference(fine, coarse) <= 0.15
      end
    end

    # The day before the source fails, so the river is steady throughout: an
    # hour step through the failure sees the river silent for the whole hour.
    test "a day of minutes, of hours and one day step agree" do
      base = region({812, day: 199, hour: 4})
      town = Ember.places().town
      fine0 = with_hearth(base, "town-hearth", town, 60)
      coarse0 = with_hearth(base, "town-hearth", town, 3_600)

      {hourly, _fine} =
        Enum.map_reduce(1..24, fine0, fn _hour, fine ->
          {fine, lines} =
            Enum.reduce(1..60, {fine, Field.zero_step()}, fn _, {f, acc} ->
              f = Region.advance(f, 1, dt: 60)
              {f, Map.merge(acc, budget(f), fn k, a, b -> if k == :dt, do: b, else: a + b end)}
            end)

          {{fine, lines}, fine}
        end)

      {hours, _coarse} =
        Enum.map_reduce(1..24, coarse0, fn _hour, coarse ->
          coarse = Region.advance(coarse, 1, dt: 3_600)
          {coarse, coarse}
        end)

      for {{fine, fine_lines}, coarse} <- Enum.zip(hourly, hours) do
        assert max_difference(fine, coarse) <= 0.5
        assert_in_delta Heat.stored_mj(field(fine)) / Heat.stored_mj(field(coarse)), 1.0, 0.005

        b = budget(coarse)
        gross = Enum.sum(for line <- @lines, do: abs(Map.fetch!(b, line)))

        for line <- @lines do
          assert_in_delta Map.fetch!(b, line), Map.fetch!(fine_lines, line), 0.03 * gross
        end
      end

      day_step = base |> with_hearth("town-hearth", town, @day) |> Region.advance(1, dt: @day)
      daily_mean = fn i -> Enum.sum(for h <- hours, do: Heat.cell_c(field(h), i)) / 24 end

      for i <- indices(field(day_step)) do
        material = elem(field(day_step).static, i).material
        tolerance = if material in [:grass, :stone, :clay], do: 0.1, else: 1.0
        assert_in_delta Heat.cell_c(field(day_step), i), daily_mean.(i), tolerance
      end
    end
  end

  describe "materials" do
    test "silt holds heat longer than stone" do
      assert Heat.tau_s(:silt) / Heat.tau_s(:stone) >= 10

      # Excess over the daily mean air, which is what the night takes away.
      mean_air = Weather.daily_mean_air_c()
      afternoon = region({813, day: 220, hour: 16})
      evening = Region.advance(afternoon, 4 * 60)
      silt = dry_silt(afternoon)

      stone_lost =
        1 -
          (background_c(field(evening), :stone) - mean_air) /
            (background_c(field(afternoon), :stone) - mean_air)

      silt_lost =
        1 -
          (Heat.cell_c(field(evening), silt) - mean_air) /
            (Heat.cell_c(field(afternoon), silt) - mean_air)

      assert stone_lost > 0.6
      assert silt_lost < 0.1
    end

    test "the table and the seepage coupling" do
      assert Heat.materials()[:silt].cap_j_m2k == 2.5e6
      # Every column is a number; silt's coupling is the base the distance law scales.
      assert Enum.all?(Heat.materials(), fn {_ground, m} -> is_float(m.k_riv_w_m2k) end)
      assert Heat.materials()[:silt].k_riv_w_m2k == 40.0
      assert Heat.k_riv_w_m2k(:silt, 2.0) == 40.0
      assert_in_delta Heat.k_riv_w_m2k(:silt, 3.0), 31.2, 0.1
      assert_in_delta Heat.k_riv_w_m2k(:silt, 6.0), 14.7, 0.1
      assert Heat.k_riv_w_m2k(:channel_bed, 0.0) == 100.0
      assert Heat.k_riv_w_m2k(:reeds, 1.5) == 40.0
      assert Heat.k_riv_w_m2k(:clay, 3.0) == 0.0
    end
  end

  describe "steam" do
    # The day before the source fails, so the river runs all evening.
    test "the banks steam at dusk while the river runs" do
      evening = region({812, day: 199, hour: 19, minute: 30})
      cell = elem(field(evening).static, bank_cell(evening, :town, 3.0)).cell

      assert %{steam?: true, air_c: air, ground_c: ground, ground: band} = Heat.at(evening, cell)
      assert ground - air >= 12
      assert band in [:warm, :hot]
      assert Heat.steaming?(field(evening), reach_near(evening, :town))

      assert %{steam?: false} = Heat.at(region({812, day: 199, hour: 13}), cell)

      # At 12 K the margin is crossed toward evening: from 16:40 at the top of
      # the river to 17:50 at its end, all within two and a half hours before
      # the 19:00 sunset ("the silt used to steam at dusk"), and never before.
      sunset = Calendar.at(812, day: 199, hour: 19)
      rises = region({812, day: 199, hour: 14}) |> Region.advance(5 * 60) |> events(:steam_rising)
      reaches = Terrain.reaches(evening.terrain)

      assert rises != []
      assert Enum.all?(rises, &(&1.entity == River.id()))
      assert Enum.sort(Enum.map(rises, & &1.data.reach)) == Enum.to_list(0..(length(reaches) - 1))
      assert Enum.map(rises, & &1.time) == Enum.sort(Enum.map(rises, & &1.time))
      assert Enum.all?(rises, &(&1.time >= sunset - 5 * @hour / 2 and &1.time <= sunset))
      assert Enum.all?(Tuple.to_list(field(region({812, day: 199, hour: 19})).steaming))

      order = Enum.map(rises, & &1.data.reach)
      {upper, lower} = Enum.split(order, div(length(order), 2))

      assert hd(order) < reach_near(evening, :town) and
               List.last(order) > reach_near(evening, :town)

      assert Enum.sum(upper) / length(upper) < Enum.sum(lower) / length(lower)

      first = hd(rises)
      assert first.data.position == Enum.at(reaches, first.data.reach).mid
    end

    test "steam is judged against the air at the end of the step" do
      # One hour step from 17:00: the air falls from 19.1 to 17.4 °C. The banks
      # clear the 12 K margin against the end-of-step air (12.3 K) and not the
      # start's (10.6 K).
      start = region({812, day: 199, hour: 17})
      town = reach_near(start, :town)
      refute Heat.steaming?(field(start), town)

      stepped = Region.advance(start, 1, dt: @hour)
      assert Heat.steaming?(field(stepped), town)
      assert Enum.any?(events(stepped, :steam_rising), &(&1.data.reach == town))
    end

    test "steam means one thing: a cell over the margin does not steam once its reach has stopped" do
      # The morning after, the air warms faster than the banks: the reach's
      # mean falls under 12 K while the silt nearest the channel is still over
      # it. The look must agree with the percept that the steam is gone.
      town = reach_near(region({812, day: 200, hour: 7}), :town)

      cell =
        elem(
          field(region({812, day: 200, hour: 7})).static,
          bank_cell(region({812, day: 200, hour: 7}), :town, 3.0)
        ).cell

      faded =
        Enum.reduce_while(1..120, region({812, day: 200, hour: 7}), fn _, r ->
          r = Region.advance(r, 1)
          {events, r} = Region.drain_events(r)

          if Enum.any?(events, &(&1.type == :steam_fading and &1.data.reach == town)),
            do: {:halt, r},
            else: {:cont, r}
        end)

      refute Heat.steaming?(field(faded), town)
      assert %{steam?: false, ground_c: ground, air_c: air} = Heat.at(faded, cell)
      assert ground - air >= 12
    end

    test "the silt cools after the source fails, and the steam fades from upstream down" do
      start = region({812, day: 200, hour: 15}, miracles: [@late_failure])
      bank = bank_cell(start, :town, 3.0)

      {stepped, samples} =
        Enum.reduce(1..240, {start, []}, fn _, {r, samples} ->
          r = Region.advance(r, 1, dt: @hour)

          if Calendar.time_of_day(r.time) == 19 * @hour,
            do: {r, [Heat.cell_c(field(r), bank) | samples]},
            else: {r, samples}
        end)

      at_19 = Enum.reverse(samples)
      assert length(at_19) == 10
      assert at_19 == Enum.sort(at_19, :desc) and Enum.uniq(at_19) == at_19
      assert_in_delta List.last(at_19), 21.0, 1.0

      {events, _} = Region.drain_events(stepped)
      day_two = Calendar.at(812, day: 201)
      rises = for %Event{type: :steam_rising} = e <- events, do: e
      fades = for %Event{type: :steam_fading} = e <- events, do: e

      assert rises != [] and Enum.all?(rises, &(&1.time < day_two))

      assert Enum.map(fades, & &1.data.reach) ==
               Enum.to_list(0..(tuple_size(field(stepped).steaming) - 1))

      assert Enum.map(fades, & &1.time) == Enum.sort(Enum.map(fades, & &1.time))
      assert Enum.all?(Tuple.to_list(field(stepped).steaming), &(&1 == false))
    end

    test "the banks do not steam beside a silent reach, however warm they still are" do
      # 812/200 20:00: the source failed at 15:00 and the town reach has run
      # silent, but its banks are still over 12 K above the air. The evening
      # before, at the same hour, the same reach ran and steamed.
      silent = region({812, day: 200, hour: 20})
      town = reach_near(silent, :town)
      assert elem(Region.get(silent, River.id(), :river).reaches, town).silent

      cell = elem(field(silent).static, bank_cell(silent, :town, 3.0)).cell
      assert %{steam?: false, ground_c: ground, air_c: air} = Heat.at(silent, cell)
      assert ground - air > 12
      refute Heat.steaming?(field(silent), town)

      flowing = region({812, day: 199, hour: 20})
      refute elem(Region.get(flowing, River.id(), :river).reaches, town).silent
      assert Heat.steaming?(field(flowing), town)
      assert %{steam?: true} = Heat.at(flowing, cell)
    end

    test "a year later the banks are cold" do
      evening = region({813, day: 220, hour: 19})
      assert Enum.all?(Tuple.to_list(field(evening).steaming), &(&1 == false))

      bank = bank_cell(evening, :town, 3.0)
      dry = dry_silt(evening)
      assert_in_delta Heat.cell_c(field(evening), bank), Heat.cell_c(field(evening), dry), 1.0

      for r <- [evening, region({813, day: 220, hour: 4})] do
        cell = elem(field(r).static, dry).cell
        assert %{ground: band, steam?: false} = Heat.at(r, cell)
        assert band != :warm and band != :hot
      end
    end
  end

  describe "the active set" do
    test "holds the channel's surroundings, the clay and two backgrounds, row-major" do
      region = region({813, day: 220, hour: 4})
      field = field(region)
      cells = Tuple.to_list(field.static)
      {real, backgrounds} = Enum.split(cells, -2)

      assert Enum.map(backgrounds, & &1.cell) == [{:background, :grass}, {:background, :stone}]
      assert Enum.all?(backgrounds, &(&1.area_m2 == 1.0 and &1.river == nil))
      keys = Enum.map(real, fn %{cell: {x, y}} -> {y, x} end)
      assert keys == Enum.sort(keys) and Enum.uniq(keys) == keys
      assert length(real) > 3_000 and length(real) < 4_000

      materials = Enum.frequencies_by(real, & &1.material)
      assert Map.has_key?(materials, :channel_bed) and Map.has_key?(materials, :clay)
      assert Enum.all?(real, &(&1.material != :silt or &1.river != nil))

      assert Enum.all?(
               real,
               &(&1.material not in [:silt, :reeds, :channel_bed] or &1.river != nil)
             )

      assert field.last_step == Field.zero_step()
      assert tuple_size(field.steaming) == length(Terrain.reaches(region.terrain))

      assert Map.keys(field.bank_cells) |> Enum.sort() ==
               Enum.to_list(0..(tuple_size(field.steaming) - 1))
    end

    test "a hearth on open grass activates its cell, from the grass background" do
      start = region({812, day: 199, hour: 4})
      cell = open_grass(start)
      assert cell != nil

      {activated, joules} = Heat.activate(field(start), start.terrain, cell)
      i = Map.fetch!(activated.index, cell)
      grass = elem(activated.energy, activated.index[{:background, :grass}])

      assert elem(activated.static, i).material == :grass
      assert elem(activated.energy, i) == 100 * grass
      assert joules == 100 * grass
      assert Map.keys(activated.index) |> length() == tuple_size(start.fields.heat.static) + 1
      {before, _} = Enum.split(Tuple.to_list(activated.static), i)
      assert Enum.all?(before, fn %{cell: {x, y}} -> {y, x} < {elem(cell, 1), elem(cell, 0)} end)
      assert Heat.activate(activated, start.terrain, cell) == {activated, 0.0}

      # Cold: the cell goes on tracking the background exactly.
      cold = start |> with_hearth("camp", cell, 60, burning: false) |> Region.advance(1)
      assert Map.has_key?(field(cold).index, cell)

      assert_in_delta Heat.ground_c(field(cold), cold.terrain, cell),
                      background_c(field(cold), :grass),
                      1.0e-9

      assert budget(cold).hearths_mj == 0.0

      # Kindled: its heat is booked and the cell warms over the background.
      lit = start |> with_hearth("camp", cell, 60) |> Region.advance(1)
      assert_in_delta budget(lit).hearths_mj, @f_ground * @hearth_w * 60 / 1.0e6, 1.0e-9
      assert Heat.ground_c(field(lit), lit.terrain, cell) > background_c(field(lit), :grass)

      # Nothing is dropped from the budget: the step starts from the field it
      # found, books what the new cell brought in as activated_mj, and the
      # storage change is the lines plus that.
      b = budget(lit)
      assert_in_delta b.activated_mj, 100 * grass / 1.0e6, 1.0e-9
      assert_in_delta b.storage_before_mj, Heat.stored_mj(field(start)), 1.0e-6
      assert_in_delta b.storage_after_mj - b.storage_before_mj, b.delta_storage_mj, 1.0e-6
      assert_in_delta b.delta_storage_mj, lines_sum(b), 1.0e-6
      assert budget(Region.advance(lit, 1)).activated_mj == 0.0

      # So the deltas of a run sum to what the run stored, activation included.
      {deltas, finish} =
        Enum.map_reduce(1..5, start |> with_hearth("camp", cell, 60), fn _, r ->
          r = Region.advance(r, 1)
          {budget(r).delta_storage_mj, r}
        end)

      assert_in_delta Enum.sum(deltas),
                      Heat.stored_mj(field(finish)) - Heat.stored_mj(field(start)),
                      1.0e-6
    end

    test "without terrain there is no field, but the air is set" do
      time = Calendar.at(813, day: 220, hour: 4)

      region =
        Region.new(id: {0, 0}, seed: 1, systems: [Weather, Heat], time: time)
        |> Region.prepare()
        |> Region.advance(3)

      refute Map.has_key?(region.fields, :heat)
      assert region.env.air_c == Weather.air_c(time + 180)
      assert Heat.at(region, {0, 0}) == nil
    end
  end

  describe "queries" do
    test "at/2 reads the bands against the air" do
      evening = region({812, day: 199, hour: 17})
      town = Ember.places().town
      assert %{air_c: air, ground_c: ground, ground: :hot, steam?: false} = Heat.at(evening, town)
      assert ground - air >= 15
      assert air == evening.env.air_c

      noon = region({812, day: 199, hour: 12})
      assert %{ground: nil} = Heat.at(noon, town)

      dawn = region({812, day: 199, hour: 6})
      stone = stone_cell(dawn)
      assert %{ground: :cold, steam?: false} = Heat.at(dawn, stone)
      assert Heat.ground_c(field(dawn), dawn.terrain, stone) == background_c(field(dawn), :stone)
    end

    test "sources/1 lists burning hearths and standing miracles, sorted by id" do
      region =
        region({813, day: 220, hour: 4})
        |> with_hearth("town-hearth", Ember.places().town, 60)
        |> with_hearth("cold-hearth", Ember.places().docks, 60, burning: false)
        |> with_coal(Ember.places().lodge, 60)

      assert [
               %{id: "the-last-coal", kind: :miracle, power_w: 800.0, name: "The Last Coal"},
               %{id: "town-hearth", kind: :hearth, power_w: 5_000.0, position: {121, 138}}
             ] = Heat.sources(Region.view(region))
    end

    test "a standing miracle warms its cell from the start" do
      lodge = Ember.places().lodge
      # The configured world has the Last Coal; build one without it to compare.
      without_coal =
        Enum.reject(Fixtures.ember_reach_opts()[:miracles], &(&1[:kind] == :standing))

      plain = region({813, day: 220, hour: 4}, miracles: without_coal)
      warmed = region({813, day: 220, hour: 4}, miracles: without_coal) |> with_coal(lodge, 60)
      # The coal must be there before the field settles.
      warmed = Region.prepare(%{warmed | fields: %{}})

      assert Heat.ground_c(field(warmed), warmed.terrain, lodge) >
               Heat.ground_c(field(plain), plain.terrain, lodge)
    end
  end

  describe "settling" do
    # Prepare's schedule (§4.3 of the spec): hourly steps and a remainder from
    # `from` to `to`, each under `reaches`.
    defp hourly(from, to, reaches) do
      Stream.unfold(from, fn
        t when t >= to -> nil
        t -> {{t, min(@hour, to - t), reaches}, t + min(@hour, to - t)}
      end)
      |> Enum.to_list()
    end

    defp forcing(t0, t1) do
      %{
        air_c: Weather.mean_air_c(t0, t1),
        sky_c: Weather.mean_sky_c(t0, t1),
        light: Daylight.mean_light(t0, t1)
      }
    end

    # Watts of standing heat per cell index, from the miracles the view lists.
    defp standing_w(region) do
      for %{kind: :miracle, position: cell, power_w: w} <- Heat.sources(Region.view(region)),
          reduce: %{} do
        acc -> Map.update(acc, field(region).index[cell], @f_ground * w, &(&1 + @f_ground * w))
      end
    end

    # What prepare must give: every cell stepped on its own with the public
    # step_field over prepare's schedule, from the equilibrium prepare starts
    # at. Two days under the river as it ran, then as long as the spring has
    # been stopped (up to two weeks) under the river as it is now.
    defp settled_cell_by_cell(region) do
      river = Region.get(region, River.id(), :river)
      spring = Region.get(region, river.source, :spring)
      daily = Weather.daily_mean_air_c()
      era = River.steady_reaches(region.terrain, spring.natural_m3_s, spring.temp_c, daily)

      # Clamped as `Heat.stopped_s/2` clamps it: a spring recorded as stopping
      # after the region's time has not been stopped at all.
      stopped =
        if spring.flow_m3_s == 0,
          do: (region.time - spring.changed_at) |> min(14 * @day) |> max(0),
          else: 0

      stop = region.time - stopped
      watts = standing_w(region)

      mean = %{
        air_c: daily,
        sky_c: daily - Weather.sky_drop(),
        light: Daylight.mean_light(0, @day)
      }

      (hourly(stop - 2 * @day, stop, era) ++ hourly(stop, region.time, river.reaches))
      |> Enum.reduce(Heat.equilibrate(field(region), mean, watts, era), fn {t0, dt, reaches}, f ->
        sources = Map.new(watts, fn {i, w} -> {i, {0.0, w * dt}} end)
        {f, _budget} = Heat.step_field(f, forcing(t0, t0 + dt), sources, reaches, dt)
        f
      end)
    end

    test "steps one cell per class and lands exactly where stepping every cell does" do
      # The river stopped two weeks and more ago, and the river still running.
      for at <- [{813, day: 220, hour: 4}, {812, day: 199, hour: 19, minute: 30}] do
        region = region(at)
        field = field(region)
        n = tuple_size(field.static)
        {us, again} = :timer.tc(fn -> Heat.prepare(region) end)
        assert field(again).energy == field.energy

        classes = Heat.settle_classes(region)
        assert classes |> Enum.concat() |> Enum.sort() == Enum.to_list(0..(n - 1))
        assert Enum.map(classes, &hd/1) == Enum.sort(Enum.map(classes, &hd/1))

        for members <- classes do
          alike =
            Enum.map(members, &Map.take(elem(field.static, &1), [:material, :area_m2, :river]))

          assert members == Enum.sort(members)
          assert length(Enum.uniq(alike)) == 1
        end

        assert settled_cell_by_cell(region).energy == field.energy

        IO.puts(
          "\nheat: prepare #{Float.round(us / 1_000, 1)} ms, #{length(classes)} classes for #{n} cells"
        )

        # Grouping by anything that names the cell would give n classes.
        assert length(classes) < div(n, 5)
      end
    end
  end

  describe "robustness" do
    test "a hearth without a last_step has given nothing" do
      start = region({812, day: 199, hour: 4})
      town = Ember.places().town

      bare =
        Region.put_entity(start, "bare", %{
          position: town,
          repr: %{name: "a bare hearth", description: nil},
          hearth: %{
            fuel_kg: 12.0,
            burning: true,
            lit_at: start.time,
            out_at: nil,
            power_w: @hearth_w,
            low_kg: 1.0
          }
        })

      stepped = Region.advance(bare, 1)
      assert budget(stepped).hearths_mj == 0.0
      assert budget(stepped).miracles_mj == 0.0
      assert field(stepped).energy == field(Region.advance(start, 1)).energy
    end

    test "at/2 falls back to the air at the view's time when none is published" do
      evening = region({812, day: 199, hour: 17})
      town = Ember.places().town
      bare = %{evening | env: Map.delete(evening.env, :air_c)}

      assert Heat.at(bare, town) == Heat.at(evening, town)
      assert Heat.at(bare, town).air_c == Weather.air_c(evening.time)
    end
  end

  describe "climate" do
    test "the wind comes from the config, with a default" do
      assert region({813, day: 220, hour: 4}).env.wind == %{from: "south-west", m_s: 2.0}

      assert region({813, day: 220, hour: 4}, climate: [wind: [from: "north", m_s: 3.0]]).env.wind ==
               %{from: "north", m_s: 3.0}
    end
  end

  describe "determinism" do
    test "the same steps give the same hash, however they are grouped" do
      start = region({812, day: 200, hour: 14}) |> with_sources(60)
      steps = [60, 3_600, 60, 600, 21_600]
      run = fn -> Enum.reduce(steps, start, &Region.advance(&2, 1, dt: &1)) end
      assert Region.state_hash(run.()) == Region.state_hash(run.())

      at_once = Region.advance(start, 30)
      one_by_one = Enum.reduce(1..30, start, fn _, r -> Region.advance(r, 1) end)
      assert Region.state_hash(at_once) == Region.state_hash(one_by_one)
    end

    test "the seed changes nothing: these systems never draw from the tick" do
      start = region({812, day: 200, hour: 14}) |> with_sources(60)
      one = Region.advance(start, 100)
      two = Region.advance(%{start | seed: start.seed + 1}, 100)

      assert one.fields == two.fields
      assert one.components.hearth == two.components.hearth
      assert Region.state_hash(one) != Region.state_hash(two)
    end
  end

  @tag :perf
  test "two hundred minute steps with every system cost under 10 ms each" do
    region = Ember.region({813, day: 220, hour: 4}) |> with_sources(60)
    {us, _} = :timer.tc(fn -> Region.advance(region, 200) end)
    mean_ms = us / 200 / 1_000

    IO.puts(
      "\nheat: #{Float.round(mean_ms, 3)} ms per step with #{length(region.systems)} systems"
    )

    assert mean_ms < 10
  end
end
