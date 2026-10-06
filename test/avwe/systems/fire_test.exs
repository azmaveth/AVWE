defmodule Avwe.Systems.FireTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Command, Event, Intent, Region}
  alias Avwe.Systems.{Fire, Miracles}
  alias Avwe.Test.Ember

  @systems [Miracles, Fire]
  @lodge "lodge-hearth"
  @coal "the-last-coal"
  @town "town-hearth"
  @mira "mira-vale"

  setup_all do
    %{region: Ember.region({813, day: 220, hour: 4}, systems: @systems)}
  end

  defp light(region, id) do
    hearth = Region.get(region, id, :hearth)
    Region.put_component(region, id, :hearth, %{hearth | burning: true, lit_at: region.time})
  end

  defp hearth(region, id), do: Region.get(region, id, :hearth)

  defp move(region, body, cell), do: Region.put_component(region, body, :position, cell)

  # Advances one step at a time, returning each step's hearth before, after
  # and the events it emitted.
  defp trace(region, id, steps, dt) do
    Enum.map_reduce(1..steps, region, fn _n, acc ->
      before = hearth(acc, id)
      {events, acc} = acc |> Region.advance(1, dt: dt) |> Region.drain_events()
      {{before, hearth(acc, id), events}, acc}
    end)
  end

  defp submit(region, verb, opts) do
    ref = Keyword.get(opts, :ref, "mira-#{verb}")
    Region.submit(region, Intent.new(@mira, verb, Keyword.put(opts, :ref, ref)))
  end

  defp run(region, steps \\ 1) do
    {events, region} = region |> Region.advance(steps) |> Region.drain_events()
    {region, events}
  end

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)
  defp of_type(events, type), do: Enum.filter(events, &(&1.type == type))

  describe "a 12 kg fire at 5 kW" do
    for dt <- [60, 3_600, 86_400] do
      test "burns out at lit_at + 38 400 s, low at 35 200 s, stepped every #{dt} s", %{
        region: region
      } do
        dt = unquote(dt)
        region = light(region, @lodge)
        lit = region.time
        steps = div(38_400 + dt - 1, dt) + 1

        {trace, after_region} = trace(region, @lodge, steps, dt)
        events = Enum.flat_map(trace, fn {_before, _after, events} -> events end)

        assert [%Event{entity: @lodge, time: low_at, data: %{position: _}}] =
                 of_type(events, :fire_low)

        assert low_at == lit + 35_200

        assert [%Event{entity: @lodge, time: out_at, data: %{reason: :fuel, by: nil}}] =
                 of_type(events, :fire_out)

        assert out_at == lit + 38_400
        assert hearth(after_region, @lodge).out_at == lit + 38_400
        refute hearth(after_region, @lodge).burning
        assert hearth(after_region, @lodge).fuel_kg == 0.0

        burned = trace |> Enum.map(fn {_b, after_h, _e} -> after_h.last_step.burned_kg end)
        assert_in_delta Enum.sum(burned), 12.0, 1.0e-9

        for {before, after_hearth, _events} <- trace, step = after_hearth.last_step do
          assert step.heat_j == step.ground_j + step.vented_j
          assert step.burned_kg == before.fuel_kg - after_hearth.fuel_kg
          assert step.smoke_g == 10 * step.burned_kg
          assert_in_delta step.ground_j, 0.3 * step.heat_j, 1.0e-6
          assert step.heat_j == 5_000.0 * step.burn_s
          refute step.miracle?
        end
      end
    end

    property "any hearth's accounting is exact at any dt" do
      check all power_w <- float(min: 100.0, max: 20_000.0),
                fuel_kg <- float(min: 0.001, max: 50.0),
                dts <-
                  list_of(member_of([1, 7, 60, 613, 3_600, 86_400]), min_length: 1, max_length: 6),
                max_runs: 50 do
        hearth = %{
          fuel_kg: fuel_kg,
          burning: true,
          lit_at: 0,
          out_at: nil,
          power_w: power_w,
          low_kg: 1.0,
          last_step: Fire.zero_step()
        }

        region =
          [id: {0, 0}, seed: 1, systems: [Fire]]
          |> Region.new()
          |> Region.put_entity("h", %{hearth: hearth, position: {3, 3}})

        Enum.reduce(dts, region, fn dt, acc ->
          before = hearth(acc, "h")
          {events, acc} = acc |> Region.advance(1, dt: dt) |> Region.drain_events()
          after_hearth = hearth(acc, "h")
          step = after_hearth.last_step

          assert step.heat_j == step.ground_j + step.vented_j
          assert step.burned_kg == before.fuel_kg - after_hearth.fuel_kg
          assert step.smoke_g == 10 * step.burned_kg
          assert step.burn_s <= dt and step.burn_s >= 0
          assert after_hearth.fuel_kg >= 0.0

          if before.burning and before.fuel_kg <= power_w / 16.0e6 * dt do
            refute after_hearth.burning
            assert [%Event{time: out_at}] = of_type(events, :fire_out)
            assert out_at == after_hearth.out_at
            assert after_hearth.fuel_kg == 0.0
          end

          acc
        end)
      end
    end

    test "a cold hearth does nothing and says so", %{region: region} do
      {[{_before, after_hearth, events}], _region} = trace(region, @lodge, 1, 3_600)
      assert after_hearth.last_step == Fire.zero_step()
      assert after_hearth.fuel_kg == 12.0
      assert of_type(events, :fire_out) == []
    end
  end

  describe "the Last Coal" do
    test "burns a day without fuel or smoke", %{region: region} do
      {trace, after_region} = trace(region, @coal, 24, 3_600)

      for {_before, coal, events} <- trace do
        assert coal.burning
        assert coal.fuel_kg == 0.0
        assert coal.last_step.burned_kg == 0.0
        assert coal.last_step.heat_j == 800.0 * 3_600
        assert coal.last_step.ground_j + coal.last_step.vented_j == coal.last_step.heat_j
        assert coal.last_step.smoke_g == 0.0
        assert coal.last_step.burn_s == 3_600.0
        assert coal.last_step.miracle?
        assert of_type(events, :fire_out) == []
      end

      assert Region.get(after_region, @coal, :repr).name == "The Last Coal"
      assert Region.get(after_region, @coal, :miracle).kind == :standing
    end

    test "cannot be doused", %{region: region} do
      {region, events} =
        region |> move(@mira, Ember.places().lodge) |> submit(:douse, target: @coal) |> run()

      assert [%{outcome: :failure, reason: :unquenchable, target: @coal}] = results(events)
      assert hearth(region, @coal).burning
      assert of_type(events, :fire_out) == []
    end
  end

  describe "kindle and douse" do
    test "light and put out the nearest hearth, each with its event", %{region: region} do
      {region, events} = region |> submit(:kindle, []) |> run()

      assert [%Event{entity: @town, time: lit_at, data: %{by: @mira, position: _}}] =
               of_type(events, :fire_lit)

      assert [%{outcome: :success, target: @town, verb: :kindle}] = results(events)
      assert %{burning: true, lit_at: ^lit_at, out_at: nil} = hearth(region, @town)
      assert hearth(region, @town).last_step.burn_s == 60.0

      {region, events} = region |> submit(:kindle, ref: "again") |> run()
      assert [%{ref: "again", outcome: :blocked, reason: :already_burning}] = results(events)

      {region, events} = region |> submit(:douse, []) |> run()
      out_at = region.time - 60

      assert [%Event{entity: @town, time: ^out_at, data: %{reason: :doused, by: @mira}}] =
               of_type(events, :fire_out)

      assert [%{outcome: :success, target: @town, verb: :douse}] = results(events)
      assert %{burning: false, out_at: ^out_at} = hearth(region, @town)

      {_region, events} = region |> submit(:douse, ref: "cold") |> run()
      assert [%{ref: "cold", outcome: :blocked, reason: :not_burning}] = results(events)
    end

    test "need a hearth within 20 m", %{region: region} do
      {x, y} = Ember.places().town

      {_region, events} = region |> move(@mira, {x + 3, y}) |> submit(:kindle, []) |> run()
      assert [%{outcome: :blocked, reason: :no_hearth}] = results(events)

      {_region, events} = region |> submit(:kindle, target: @lodge) |> run()
      assert [%{outcome: :blocked, reason: :too_far}] = results(events)

      {_region, events} = region |> submit(:kindle, target: "the-hearth-of-nowhere") |> run()
      assert [%{outcome: :blocked, reason: :no_such_hearth}] = results(events)

      {_region, events} = region |> move(@mira, {x + 2, y}) |> submit(:kindle, []) |> run()
      assert [%{outcome: :success, target: @town}] = results(events)
    end

    test "need something to burn", %{region: region} do
      town = hearth(region, @town)

      {_region, events} =
        region
        |> Region.put_component(@town, :hearth, %{town | fuel_kg: 0.0})
        |> submit(:kindle, [])
        |> run()

      assert [%{outcome: :blocked, reason: :no_fuel}] = results(events)
    end

    test "a standing miracle counts as fuel", %{region: region} do
      coal = hearth(region, @coal)

      {_region, events} =
        region
        |> Region.put_component(@coal, :hearth, %{coal | burning: false})
        |> move(@mira, Ember.places().lodge)
        |> submit(:kindle, target: @coal)
        |> run()

      assert [%{outcome: :success, target: @coal}] = results(events)
    end

    test "are what the telnet player types, with or without a hearth's name" do
      for line <- ["kindle", "light", "light the fire", "light fire", "light the hearth"],
          do: assert(Command.parse(line) == {:kindle, nil})

      for line <- ["douse", "douse the fire", "put out", "put out the fire", "put out fire"],
          do: assert(Command.parse(line) == {:douse, nil})

      assert Command.parse("light the lodge hearth") == {:kindle, "lodge hearth"}
      assert Command.parse("kindle the kiln-house hearth") == {:kindle, "kiln-house hearth"}
      assert Command.parse("douse the coal") == {:douse, "coal"}
      assert Command.parse("Douse The Last Coal") == {:douse, "last coal"}

      assert Command.parse("put out the fire in the kiln-house hearth") ==
               {:douse, "kiln-house hearth"}

      assert Command.parse("put the fire out") == {:unknown, "put the fire out"}
    end
  end

  describe "felt warmth" do
    test "comes from the strongest fire within two cells", %{region: region} do
      lodge = Ember.places().lodge
      {x, y} = lodge

      assert %{ref: @coal, name: "The Last Coal", level: :warm} = Fire.felt(region, lodge)

      lit = light(region, @lodge)
      assert %{ref: @lodge, name: "the lodge hearth", level: :hot} = Fire.felt(lit, lodge)
      assert %{ref: @lodge, level: :faint} = Fire.felt(lit, {x + 1, y})
      assert Fire.felt(lit, {x + 2, y}) == nil
      assert Fire.felt(region, {x + 1, y}) == nil

      # Every source within reach, strongest first.
      assert [%{ref: @lodge, level: :hot}, %{ref: @coal, level: :warm}] =
               Fire.felt_all(lit, lodge)

      assert [%{ref: @lodge, level: :faint}] = Fire.felt_all(lit, {x + 1, y})
      assert Fire.felt_all(lit, {x + 2, y}) == []
    end

    test "is nothing from a cold hearth", %{region: region} do
      assert Fire.felt(region, Ember.places().town) == nil
    end
  end

  test "hearth_near lists hearths by distance then id", %{region: region} do
    {x, y} = Ember.places().lodge

    assert [{@lodge, _hearth, +0.0}, {@coal, _coal, +0.0}] = Fire.hearth_near(region, {x, y})
    assert [{@lodge, _, 2.0}, {@coal, _, 2.0}] = Fire.hearth_near(region, {x + 2, y})
    assert Fire.hearth_near(region, {x + 3, y}) == []
    assert Fire.hearth_near(Region.view(region), {x, y}) == Fire.hearth_near(region, {x, y})
  end

  test "hearth_near's order owes nothing to the order the component map yields" do
    {x, y} = cell = {50, 50}
    ids = for n <- 0..39, do: "hearth-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
    {evens, odds} = Enum.split_with(Enum.with_index(ids), fn {_id, n} -> rem(n, 2) == 0 end)

    hearth = %{
      fuel_kg: 1.0,
      burning: false,
      lit_at: nil,
      out_at: nil,
      power_w: 1_000.0,
      low_kg: 1.0,
      last_step: Fire.zero_step()
    }

    placed =
      Enum.map(evens, fn {id, _n} -> {id, cell} end) ++
        Enum.map(odds, fn {id, _n} -> {id, {x + 2, y}} end)

    region =
      Enum.reduce(placed, Region.new(id: {0, 0}, seed: 1, systems: [Fire]), fn {id, at}, acc ->
        Region.put_entity(acc, id, %{hearth: hearth, position: at})
      end)

    # Past 32 keys a map stops iterating in key order, so a sort that leaned
    # on it would show here.
    refute Map.keys(region.components.hearth) == ids

    assert Enum.map(Fire.hearth_near(region, cell), fn {id, _hearth, d} -> {id, d} end) ==
             Enum.map(evens, fn {id, _n} -> {id, 0.0} end) ++
               Enum.map(odds, fn {id, _n} -> {id, 2.0} end)
  end
end
