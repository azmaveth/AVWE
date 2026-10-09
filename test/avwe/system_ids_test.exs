defmodule Avwe.SystemIdsTest do
  @moduledoc """
  A region lists its systems by id, a table says which module runs an id
  (`Avwe.SystemTable`), and a system may have a period.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.{Event, Region, SystemTable}

  # Every test uses ids of its own: the table is global.

  defmodule Counter do
    @moduledoc false
    @behaviour Avwe.System

    # Counts the steps it ran in, and says what tick it was given.
    @impl Avwe.System
    def system_id, do: "test.ids.counter/step"

    @impl Avwe.System
    def run(region, tick) do
      count = Map.get(region.env, :count, 0) + 1

      {Region.put_env(region, :count, count),
       [Event.new(:counted, data: %{count: count, time: tick.time, dt: tick.dt})]}
    end
  end

  defmodule Rival do
    @moduledoc false
    @behaviour Avwe.System

    # Declares the id that Counter runs.
    @impl Avwe.System
    def system_id, do: "test.ids.counter/step"

    @impl Avwe.System
    def run(region, _tick), do: {region, []}
  end

  defmodule Unnamed do
    @moduledoc false
    @behaviour Avwe.System

    @impl Avwe.System
    def run(region, _tick), do: {region, []}
  end

  defmodule Before do
    @moduledoc false
    @behaviour Avwe.System

    @impl Avwe.System
    def system_id, do: "test.ids.moved/step"

    @impl Avwe.System
    def run(region, _tick), do: {Region.put_env(region, :who, :before), []}
  end

  defmodule After do
    @moduledoc false
    @behaviour Avwe.System

    # The same system, in another module: the one that moved.
    @impl Avwe.System
    def system_id, do: "test.ids.moved/step"

    @impl Avwe.System
    def run(region, _tick), do: {Region.put_env(region, :who, :after), []}
  end

  defp region(systems, opts \\ []) do
    Region.new([id: {0, 0}, seed: 1, systems: systems] ++ opts)
  end

  describe "ids" do
    test "a system names its id, and a module that does not is known by its name" do
      assert SystemTable.id(Counter) == "test.ids.counter/step"
      assert SystemTable.id(Unnamed) == "module:Avwe.SystemIdsTest.Unnamed"
    end

    test "every system of the engine declares an id of its rule's, and they are all different" do
      systems =
        :avwe
        |> Application.spec(:modules)
        |> Enum.filter(fn module ->
          String.starts_with?(inspect(module), "Avwe.Systems.") and
            Avwe.System in (module.module_info(:attributes)[:behaviour] || [])
        end)

      ids = Enum.map(systems, &SystemTable.id/1)

      assert length(systems) == 12
      assert length(Enum.uniq(ids)) == 12
      assert Enum.all?(ids, &String.match?(&1, ~r{\A(sim|play|earthlike\.[a-z]+)/[a-z]+\z}))
    end

    test "a region keeps the id and its options, given a module, an id or a pair" do
      assert region([Counter]).systems == [{"test.ids.counter/step", []}]
      assert region(["test.ids.counter/step"]).systems == [{"test.ids.counter/step", []}]

      assert region([{Counter, every: 300}]).systems == [{"test.ids.counter/step", [every: 300]}]

      assert region([{"test.ids.counter/step", every: 300}]).systems ==
               region([{Counter, every: 300}]).systems
    end

    test "what a region keeps is what it accepts again" do
      kept = region([Counter, {Unnamed, every: 60}]).systems

      assert region(kept).systems == kept
    end

    test "an id that no module runs is refused, in words" do
      assert_raise ArgumentError, ~r/no rule declares the system "test.ids.nobody\/step"/, fn ->
        region(["test.ids.nobody/step"])
      end
    end

    test "two modules cannot declare one id" do
      region([Counter])

      assert_raise ArgumentError, ~r/belongs to .*Counter.*and .*Rival.* declares it too/, fn ->
        region([Rival])
      end
    end

    test "the hash of a region sees the ids and not the modules" do
      by_module = region([Counter]) |> Region.advance(3)
      by_id = region(["test.ids.counter/step"]) |> Region.advance(3)

      assert Region.state_hash(by_module) == Region.state_hash(by_id)
      refute inspect(by_module.systems) =~ "Counter"
    end

    test "an id of a rule the engine ships is found even when the table was never told of it" do
      :persistent_term.erase({SystemTable, "earthlike.fire/step"})

      assert SystemTable.fetch("earthlike.fire/step") == {:ok, Avwe.Systems.Fire}

      assert SystemTable.missing(["earthlike.fire/step", "test.ids.never/step"]) == [
               "test.ids.never/step"
             ]
    end

    test "a system that moved to another module runs from there, for a region that was saved" do
      saved = region([Before]) |> Region.advance(1)
      assert saved.env.who == :before

      :ok = SystemTable.put("test.ids.moved/step", After)
      resumed = Region.advance(saved, 1)

      assert resumed.env.who == :after
      assert resumed.systems == saved.systems
    end
  end

  describe "periods" do
    defp counted(region) do
      {events, _region} = Region.drain_events(region)
      for %Event{type: :counted, data: data} <- events, do: {data.time, data.dt}
    end

    test "a system with a period runs in the step that reaches a multiple of it, told the period it covers" do
      region = region([{Counter, every: 300}]) |> Region.advance(10)

      # Steps of 60 s end at 60, 120, ...: the ones ending at 300 and 600 reach a multiple.
      assert counted(region) == [{0, 300}, {300, 300}]
    end

    test "a period counts from the clock and not from the start" do
      region = region([{Counter, every: 300}], time: 100) |> Region.advance(10)

      # Steps end at 160, 220, 280, 340 (crosses 300), ..., 640 (crosses 600).
      assert counted(region) == [{40, 300}, {340, 300}]
    end

    test "a step as long as the period, or longer, runs the system as it is" do
      region = region([{Counter, every: 300}], dt: 600) |> Region.advance(3)

      assert counted(region) == [{0, 600}, {600, 600}, {1200, 600}]
    end

    test "a system without a period runs every step" do
      region = region([Counter]) |> Region.advance(4)

      assert counted(region) == [{0, 60}, {60, 60}, {120, 60}, {180, 60}]
    end

    property "advancing many steps at once equals advancing one at a time, periods included" do
      check all every <- member_of([90, 300, 3_600, 86_400]),
                start <- integer(0..100_000),
                steps <- integer(1..40) do
        start_region = region([{Counter, every: every}], time: start)

        one_at_a_time =
          Enum.reduce(1..steps, start_region, fn _n, acc -> Region.advance(acc, 1) end)

        assert Region.state_hash(Region.advance(start_region, steps)) ==
                 Region.state_hash(one_at_a_time)
      end
    end
  end
end
