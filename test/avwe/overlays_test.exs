defmodule Avwe.OverlaysTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Overlays, Region, Rle}
  alias Avwe.Systems.Heat
  alias Avwe.Test.Ember

  @town_hearth "town-hearth"

  # What a client is given: the region's changing state with its fields, and its terrain.
  defp snapshot(region), do: region |> Region.snapshot() |> Map.put(:terrain, region.terrain)

  defp ember(at), do: Ember.region(at)

  # The hour before the source fails, and the river drying from it.
  defp flowing, do: ember({812, day: 200, hour: 14})
  defp dry, do: ember({813, day: 220, hour: 12})

  defp light(region, id) do
    hearth = Region.get(region, id, :hearth)
    Region.put_component(region, id, :hearth, %{hearth | burning: true, lit_at: region.time})
  end

  defp silent(region), do: region |> snapshot() |> Overlays.water() |> Enum.map(& &1.silent)

  defp decoded(rows), do: Enum.map(rows, &Rle.decode/1)

  @alphabet "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  # The mean level the overlay draws the silt cells at, read from its rows.
  defp bank_level(region) do
    snapshot = snapshot(region)
    field = snapshot.fields.heat
    rows = snapshot |> Overlays.heat() |> Map.fetch!(:rows) |> decoded()

    levels =
      for {{x, y}, i} <- field.index, is_integer(x), elem(field.static, i).material == :silt do
        rows |> Enum.at(y) |> Enum.at(x) |> then(&(:binary.match(@alphabet, &1) |> elem(0)))
      end

    assert length(levels) > 1_500
    Enum.sum(levels) / length(levels)
  end

  describe "water" do
    test "is one entry for each reach of the river, from the source to the exit" do
      reaches = flowing() |> snapshot() |> Overlays.water()

      assert length(reaches) == 23
      assert Enum.all?(reaches, &(Map.keys(&1) |> Enum.sort() == [:silent, :steaming, :temp_c]))
    end

    test "runs before the source fails, and has fallen silent everywhere after it" do
      refute flowing() |> silent() |> Enum.all?()
      assert flowing() |> silent() |> Enum.any?(&(&1 == false))
      assert dry() |> silent() |> Enum.all?()
    end

    test "falls silent from the source down, one reach after another, as the river drains" do
      region = ember({812, day: 200, hour: 15})
      one = Enum.map(0..4, fn n -> silent(Region.advance(region, 40 * n)) end)

      for flags <- one do
        # Silent reaches are the first ones: a run of true, then a run of false.
        assert flags == Enum.sort(flags, :desc)
      end

      counts = Enum.map(one, fn flags -> Enum.count(flags, & &1) end)
      assert counts == Enum.sort(counts)
      assert List.first(counts) < List.last(counts)
      assert Enum.uniq(counts) |> length() > 2
    end

    test "has the water's temperature to a tenth of a degree" do
      for reach <- flowing() |> snapshot() |> Overlays.water() do
        assert is_float(reach.temp_c)
        assert reach.temp_c == Float.round(reach.temp_c, 1)
      end
    end

    test "says a reach steams where the heat system says it does" do
      for region <- [flowing(), dry(), ember({812, day: 200, hour: 5})] do
        snapshot = snapshot(region)
        field = snapshot.fields.heat

        for {reach, k} <- snapshot |> Overlays.water() |> Enum.with_index() do
          assert reach.steaming == Heat.steaming?(field, k), "reach #{k}"
        end
      end
    end

    test "is empty for a world with no river" do
      assert Overlays.water(%{components: %{}}) == []
      assert Overlays.water(%{components: %{river: %{}}}) == []
    end
  end

  describe "heat" do
    setup do
      %{snapshot: snapshot(dry())}
    end

    test "is rows over the whole map, each as wide as the map", %{snapshot: snapshot} do
      heat = Overlays.heat(snapshot)

      assert heat.base == -10 and heat.step == 1
      assert length(heat.rows) == snapshot.terrain.height

      for cells <- decoded(heat.rows), do: assert(length(cells) == snapshot.terrain.width)
    end

    test "draws every stored cell at its temperature's level, and nothing else", %{
      snapshot: snapshot
    } do
      field = snapshot.fields.heat
      rows = snapshot |> Overlays.heat() |> Map.fetch!(:rows) |> decoded()

      stored =
        for {{x, _y} = cell, i} <- field.index, is_integer(x), do: {cell, i}

      drawn =
        for {cells, y} <- Enum.with_index(rows),
            {letter, x} <- Enum.with_index(cells),
            letter != ".",
            do: {x, y}

      assert length(stored) > 3_000
      assert Enum.sort(drawn) == stored |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      alphabet = String.graphemes("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

      for {{x, y}, i} <- stored do
        letter = rows |> Enum.at(y) |> Enum.at(x)

        assert letter == Enum.at(alphabet, Overlays.heat_level(Heat.cell_c(field, i))),
               "#{x},#{y}"
      end
    end

    test "leaves a cell the heat system does not store to its ground's background", %{
      snapshot: snapshot
    } do
      rows = snapshot |> Overlays.heat() |> Map.fetch!(:rows) |> decoded()

      assert rows |> Enum.at(0) |> Enum.at(0) == "."
      assert rows |> List.last() |> List.last() == "."
    end

    test "gives the two backgrounds and the air, to a tenth of a degree", %{snapshot: snapshot} do
      field = snapshot.fields.heat
      heat = Overlays.heat(snapshot)

      assert heat.backgrounds.grass ==
               Float.round(Heat.cell_c(field, field.index[{:background, :grass}]), 1)

      assert heat.backgrounds.stone ==
               Float.round(Heat.cell_c(field, field.index[{:background, :stone}]), 1)

      assert heat.air_c == Float.round(snapshot.env.air_c, 1)
    end

    # The river's seepage keeps the silt banks warm; with the river gone they
    # cool, and the overlay, which only reads the field, shows it: 2 057 silt
    # cells are about three degrees cooler sixteen hours after the source
    # fails than if it had run on (a day's swing in the open is twenty-four).
    test "shows the silt banks cooler once the river has dried than they would have been had it run on" do
      at = {812, day: 200, hour: 14}
      dried = at |> ember() |> Region.advance(16 * 60)
      running = at |> Ember.region(miracles: []) |> Region.advance(16 * 60)

      assert bank_level(running) - bank_level(dried) >= 2
      assert bank_level(running) > bank_level(dried)
    end

    test "is nothing for a world with no heat" do
      assert Overlays.heat(%{components: %{}}) == nil
      assert Overlays.heat(%{components: %{}, fields: %{}}) == nil
    end
  end

  describe "heat_level/1" do
    test "is 0 at the base, a level a degree, and the ends for what is beyond them" do
      assert Overlays.heat_level(-10) == 0
      assert Overlays.heat_level(0) == 10
      assert Overlays.heat_level(15.4) == 25
      assert Overlays.heat_level(15.6) == 26
      assert Overlays.heat_level(41) == 51
      assert Overlays.heat_level(-300) == 0
      assert Overlays.heat_level(900) == 51
    end

    property "never falls as the temperature rises, and stays in its fifty-two levels" do
      check all(
              a <- StreamData.float(min: -400.0, max: 1_200.0),
              b <- StreamData.float(min: -400.0, max: 1_200.0)
            ) do
        {low, high} = if a <= b, do: {a, b}, else: {b, a}

        assert Overlays.heat_level(low) <= Overlays.heat_level(high)
        assert Overlays.heat_level(low) in 0..51
      end
    end
  end

  describe "smoke" do
    defp puffs(list), do: %{fields: %{smoke: %{puffs: list}}}

    test "is each puff's place to a tenth of a cell and its mass to two figures, in order" do
      puffs = [
        %{x: 94.54, y: 111.26, g: 0.1834, born: 0},
        %{x: 3.0, y: 2.0, g: 12.34, born: 0},
        %{x: 3.0, y: 1.0, g: 123.456, born: 0}
      ]

      assert Overlays.smoke(puffs(puffs)) ==
               [[3.0, 1.0, 123.0], [3.0, 2.0, 12.0], [94.5, 111.3, 0.18]]
    end

    test "leaves out a puff with nothing in it" do
      puffs = [%{x: 1.0, y: 1.0, g: 0.0, born: 0}, %{x: 2.0, y: 2.0, g: 0.5, born: 0}]

      assert Overlays.smoke(puffs(puffs)) == [[2.0, 2.0, 0.5]]
    end

    test "is what a lit hearth gives off, drifting, inside the map" do
      region = dry() |> light(@town_hearth) |> Region.advance(30)
      puffs = region |> snapshot() |> Overlays.smoke()

      assert length(puffs) > 4
      assert puffs == Enum.sort(puffs)

      for [x, y, g] <- puffs do
        assert x >= 0 and x < 256 and y >= 0 and y < 256
        assert g > 0
      end
    end

    test "is none where no fire has burned, or the world has no smoke" do
      assert dry() |> snapshot() |> Overlays.smoke() == []
      assert Overlays.smoke(%{components: %{}}) == []
    end
  end
end
