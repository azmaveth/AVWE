defmodule Avwe.GuestsTest do
  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Guests, Intent, Quire, Region, Worldgen}
  alias Avwe.Systems.{Daylight, Movement, Waiting}
  alias Avwe.Test.Fixtures

  @systems [Daylight, Movement, Waiting]
  @arrival "hollow-green"

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  # Lantern Hollow at noon, with a place nobody pinned (the way the river's
  # source is) and a hearth, to be named after.
  defp hollow(world) do
    world
    |> Quire.Seed.region(id: {0, 0}, seed: 1, time: Calendar.at(1, hour: 12), systems: @systems)
    |> Worldgen.add_characters(wren: [])
    |> Region.put_entity("hidden-spring", %{
      place: %{label: "The Hidden Spring"},
      position: {3, 3},
      repr: %{name: "The Hidden Spring", description: nil}
    })
    |> Region.put_entity("green-fire-pit", %{
      hearth: %{burning: false, fuel_kg: 1.0},
      repr: %{name: "the fire pit on the green", description: nil}
    })
    |> Region.prepare()
  end

  defp arrival(name, backstory \\ nil, opts \\ []) do
    {:ok, %{id: id}} = Guests.offer(name, backstory)

    Intent.new(id, :arrive,
      ref: "arrive-#{id}",
      controller: :mcp,
      params: %{
        name: name,
        backstory: backstory,
        arrival: Keyword.get(opts, :arrival, @arrival),
        max: Keyword.get(opts, :max, 3)
      }
    )
  end

  defp run(region, steps \\ 1) do
    {events, region} = region |> Region.advance(steps) |> Region.drain_events()
    {region, events}
  end

  defp arrive(region, intent), do: region |> Region.submit(intent) |> run()

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)

  describe "offer/2" do
    test "makes the id of a body from the name's words" do
      assert {:ok, %{id: "guest-tomas-reed", name: "Tomas Reed", backstory: nil}} =
               Guests.offer("Tomas Reed", nil)

      assert {:ok, %{id: "guest-tomas-reed"}} = Guests.offer("  Tomás   Reed ", nil)
      assert {:ok, %{id: "guest-o-brien"}} = Guests.offer("O'Brien", nil)
      assert {:ok, %{id: "guest-wen-li"}} = Guests.offer("Wen-Li", nil)
    end

    test "gives a name in another script an id of a hash of itself" do
      assert {:ok, %{id: "guest-" <> hash, name: "山田 太郎"}} = Guests.offer("山田 太郎", nil)
      assert hash =~ ~r/\A\d+\z/
      assert {:ok, %{id: "guest-" <> ^hash}} = Guests.offer("山田 太郎", nil)
    end

    test "makes the name and the backstory one line of plain text" do
      assert {:ok, %{name: "Tomas Reed", backstory: "A diver. Came by the road."}} =
               Guests.offer("Tomas\n \e[31mReed\e[0m", "A diver.\n\tCame by\e]0;x\a the road.\0")
    end

    test "refuses a name of the wrong length, or of other characters, or without letters" do
      for name <- [
            "A",
            String.duplicate("a", 41),
            "Tom <b>",
            "Tom_Reed",
            "12 34",
            "- .",
            "",
            nil,
            7
          ] do
        assert {:error, :invalid_name} = Guests.offer(name, nil), inspect(name)
      end

      assert {:ok, _guest} = Guests.offer(String.duplicate("a", 40), nil)
      assert {:ok, _guest} = Guests.offer("Al", nil)
    end

    test "refuses the words the world uses for people it cannot name" do
      for name <- ["You", "someone", "ANYONE", "Nobody", "Everyone", "Stranger"] do
        assert {:error, :invalid_name} = Guests.offer(name, nil), name
      end
    end

    test "takes a backstory of up to a thousand characters, or none" do
      assert {:ok, %{backstory: nil}} = Guests.offer("Tomas Reed", "")
      assert {:ok, %{backstory: nil}} = Guests.offer("Tomas Reed", " \n ")
      assert {:ok, %{backstory: story}} = Guests.offer("Tomas Reed", String.duplicate("b", 1_000))
      assert String.length(story) == 1_000

      assert {:error, :invalid_backstory} =
               Guests.offer("Tomas Reed", String.duplicate("b", 1_001))

      assert {:error, :invalid_backstory} = Guests.offer("Tomas Reed", 7)
    end
  end

  describe "arriving" do
    test "makes a body at the arrival place that knows the pinned places and not the unpinned", %{
      world: world
    } do
      {region, events} = world |> hollow() |> arrive(arrival("Tomas Reed", "A diver."))
      id = "guest-tomas-reed"

      assert %{body: _body, repr: %{name: "Tomas Reed", description: "A guest."}} =
               Region.entity(region, id)

      assert Region.get(region, id, :guest).backstory == "A diver."
      assert Region.get(region, id, :position) == Region.get(region, @arrival, :position)
      assert Region.get(region, id, :control) == %{holder: nil, since: nil}
      assert Region.get(region, id, :autopilot) != nil

      knows = Region.get(region, id, :knows)
      assert MapSet.member?(knows, @arrival)
      assert MapSet.member?(knows, "mill-pond")
      refute MapSet.member?(knows, "hidden-spring")

      assert [%{ref: "arrive-guest-tomas-reed", verb: :arrive, outcome: :success}] =
               results(events)

      assert Enum.any?(
               events,
               &match?(
                 %Event{type: :arrived, entity: ^id, data: %{place: @arrival, position: _}},
                 &1
               )
             )
    end

    test "gives the guest a pocket notebook it carries", %{world: world} do
      {region, _events} = world |> hollow() |> arrive(arrival("Tomas Reed"))
      notebook = Guests.notebook("guest-tomas-reed")

      assert %{carried_by: "guest-tomas-reed", notebook: %{pages: []}, item: %{kind: :notebook}} =
               Region.entity(region, notebook)
    end

    test "is a body like any other: it goes places it knows, and writes in its notebook", %{
      world: world
    } do
      {region, _events} = world |> hollow() |> arrive(arrival("Tomas Reed"))

      region =
        region
        |> Region.submit(
          Intent.new("guest-tomas-reed", :write,
            ref: "w-1",
            params: %{text: "I came by the road."}
          )
        )
        |> Region.submit(Intent.new("guest-tomas-reed", :go, ref: "g-1", target: "mill-pond"))

      {region, events} = run(region, 40)

      assert [%{ref: "w-1", outcome: :success}, %{ref: "g-1", outcome: :success}] =
               results(events)

      assert Region.get(region, "guest-tomas-reed", :position) ==
               Region.get(region, "mill-pond", :position)

      assert [%{text: "I came by the road."}] =
               Region.get(region, Guests.notebook("guest-tomas-reed"), :notebook).pages
    end

    test "is told apart from nobody in the same step: the arrival is first, its control second",
         %{world: world} do
      region = hollow(world)
      intent = arrival("Tomas Reed")

      {region, events} =
        region
        |> Region.submit(intent)
        |> Region.submit(Intent.new(intent.body, :control, ref: "c-1", controller: :mcp))
        |> run()

      assert [%{verb: :arrive, outcome: :success}, %{verb: :control, outcome: :success}] =
               results(events)

      assert %{holder: :mcp} = Region.get(region, intent.body, :control)
    end

    test "is deterministic: the same arrival gives the same region", %{world: world} do
      hash = fn ->
        {region, _events} = world |> hollow() |> arrive(arrival("Tomas Reed", "A diver."))
        Region.state_hash(region)
      end

      assert hash.() == hash.()
    end
  end

  describe "refusing" do
    test "an arrival with the id of a body that is there, or a name that is taken", %{
      world: world
    } do
      region = hollow(world)

      for name <- [
            "Wren",
            "WREN",
            "Tamsín",
            "Hollow Green",
            "mill pond",
            "The Fire Pit on the Green",
            "Hidden-Spring",
            "Wren.",
            "Mill-Pond.",
            "T.a.m.s.i.n"
          ] do
        intent = arrival(name)
        {_region, events} = arrive(region, intent)

        assert [%{verb: :arrive, outcome: :blocked, reason: :name_taken}] = results(events), name
        assert {:error, :name_taken} = Guests.check(region, intent), name
      end
    end

    test "an intent whose body is not the id of its name", %{world: world} do
      region = hollow(world)
      intent = %{arrival("Tomas Reed") | body: "mira-vale"}

      assert {:error, :invalid_name} = Guests.check(region, intent)
      {_region, events} = arrive(region, intent)
      assert [%{outcome: :blocked, reason: :invalid_name}] = results(events)
    end

    test "a guest by a name a guest has", %{world: world} do
      {region, _events} = world |> hollow() |> arrive(arrival("Tomas Reed"))

      assert {:error, :name_taken} = Guests.check(region, arrival("tomas  reed"))
      assert {:error, :name_taken} = Guests.check(region, arrival("Tomás Reed"))
    end

    test "an arrival past the most the world takes, counting those waiting for the next step", %{
      world: world
    } do
      region = hollow(world)
      one = arrival("Tomas Reed", nil, max: 2)
      two = arrival("Ines Cole", nil, max: 2)
      three = arrival("Pim Aldous", nil, max: 2)

      assert :ok = Guests.check(region, one)
      region = Region.submit(region, one)
      assert :ok = Guests.check(region, two)
      region = Region.submit(region, two)
      assert {:error, :full} = Guests.check(region, three)

      {region, events} = run(region)
      assert [%{outcome: :success}, %{outcome: :success}] = results(events)
      assert {:error, :full} = Guests.check(region, three)
    end

    test "an arrival waiting under the name another is waiting under", %{world: world} do
      region = hollow(world) |> Region.submit(arrival("Tomas Reed"))
      assert {:error, :name_taken} = Guests.check(region, arrival("Tomas  Reed"))
    end

    test "an arrival at a place that is not one, or at no place, or with no most", %{world: world} do
      region = hollow(world)

      assert {:error, :no_arrival_place} =
               Guests.check(region, arrival("Tomas Reed", nil, arrival: "wren"))

      assert {:error, :no_arrival_place} =
               Guests.check(region, arrival("Tomas Reed", nil, arrival: "atlantis"))

      intent = arrival("Tomas Reed")

      assert {:error, :no_guests} =
               Guests.check(region, %{intent | params: Map.delete(intent.params, :arrival)})

      assert {:error, :no_guests} =
               Guests.check(region, %{intent | params: %{intent.params | max: 0}})
    end

    test "every refusal is one result, and makes nobody", %{world: world} do
      region = hollow(world)
      before = Region.state_hash(region)

      {refused, events} = arrive(region, arrival("Wren"))

      assert [%{outcome: :blocked}] = results(events)
      assert Region.with_components(refused, [:guest]) == []
      refute Region.state_hash(refused) == before
      assert Region.entity(refused, "guest-wren") == %{}
    end
  end

  describe "a guest left alone" do
    test "stays where it is through a day, as a body with no routine does", %{world: world} do
      {region, _events} = world |> hollow() |> arrive(arrival("Tomas Reed"))
      position = Region.get(region, "guest-tomas-reed", :position)

      {region, _events} = run(region, 24 * 60)

      assert Region.get(region, "guest-tomas-reed", :position) == position
      assert Region.get(region, "guest-tomas-reed", :body) != nil
    end
  end
end
