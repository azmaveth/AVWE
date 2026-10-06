defmodule Avwe.NotebookTest do
  @moduledoc """
  The notebook: an item a body carries, and the `:write` and `:read` verbs.
  Lantern Hollow at noon, where Wren carries a notebook and Tamsin carries
  two; Pell carries none.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Calendar, Event, Intent, Perception, Prose, Quire, Region, Worldgen}
  alias Avwe.Systems.{Daylight, Movement, Waiting}
  alias Avwe.Test.{Ember, Fixtures}

  @systems [Daylight, Movement, Waiting]

  setup_all do
    {:ok, world} = Quire.load(Fixtures.lantern_hollow())
    %{world: world}
  end

  defp hollow(world) do
    world
    |> Quire.Seed.region(id: {0, 0}, seed: 1, time: Calendar.at(1, hour: 12), systems: @systems)
    |> Worldgen.add_characters(
      wren: [carries: [[id: "wren-notebook", kind: :notebook, name: "field notebook"]]],
      tamsin: [
        carries: [
          [id: "tamsin-b", kind: :notebook, name: "blue notebook"],
          [id: "tamsin-a", kind: :notebook, name: "red notebook", description: "Dog-eared."]
        ]
      ]
    )
    |> Region.prepare()
  end

  defp submit(region, body, verb, opts) do
    ref = Keyword.get(opts, :ref, "#{body}-#{verb}")
    Region.submit(region, Intent.new(body, verb, Keyword.put(opts, :ref, ref)))
  end

  defp run(region, steps \\ 1) do
    {events, region} = region |> Region.advance(steps) |> Region.drain_events()
    {region, events}
  end

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)

  defp pages(region, id), do: Region.get(region, id, :notebook).pages

  defp write(region, body, text, opts \\ []),
    do: submit(region, body, :write, [params: %{text: text}] ++ opts)

  defp view(region), do: region |> Region.view() |> Map.put(:terrain, region.terrain)

  describe "the item" do
    test "is an entity carried by its body, with an empty notebook", %{world: world} do
      region = hollow(world)

      assert Region.entity(region, "tamsin-a") == %{
               item: %{kind: :notebook},
               carried_by: "tamsin",
               repr: %{name: "red notebook", description: "Dog-eared."},
               notebook: %{pages: []}
             }
    end

    test "is checked when the world is built", %{world: world} do
      region = Quire.Seed.region(world, id: {0, 0}, seed: 1)

      bad = [
        [[id: "wren", kind: :notebook, name: "n"]],
        [[id: "x", kind: :hat, name: "n"]],
        [[id: "x", kind: :notebook]],
        [[id: "", kind: :notebook, name: "n"]],
        [[id: "x", kind: :notebook, name: "n", description: 7]],
        [[id: "x", kind: :notebook, name: "n"], [id: "x", kind: :notebook, name: "m"]],
        [:notebook],
        :notebook
      ]

      for carries <- bad do
        assert_raise ArgumentError, fn ->
          Worldgen.add_characters(region, wren: [carries: carries])
        end
      end
    end

    test "Mira carries her survey notebook in the Ember Reach" do
      region = Ember.region()
      assert Region.get(region, "mira-notebook", :carried_by) == "mira-vale"
      assert Region.get(region, "mira-notebook", :repr).name == "survey notebook"
    end
  end

  describe "write" do
    test "appends a page stamped with the step's end, the time its result reports, trimmed", %{
      world: world
    } do
      region = hollow(world)

      {region, events} = region |> write("wren", "  The pond is low.  ") |> run()

      assert [%Event{time: written, data: %{outcome: :success} = data}] =
               Enum.filter(events, &(&1.type == :action_result))

      assert %{target: "wren-notebook", params: %{text: "The pond is low."}} = data
      assert written == region.time
      assert pages(region, "wren-notebook") == [%{time: written, text: "The pond is low."}]

      {region, _events} = region |> write("wren", "Second.") |> run()

      assert Enum.map(pages(region, "wren-notebook"), & &1.text) == [
               "The pond is low.",
               "Second."
             ]
    end

    test "goes in the named notebook, or the first carried by id", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> write("tamsin", "first by id", ref: "a")
        |> write("tamsin", "named", target: "tamsin-b", ref: "b")
        |> run()

      assert [%{ref: "a", target: "tamsin-a"}, %{ref: "b", target: "tamsin-b"}] = results(events)
      assert [%{text: "first by id"}] = pages(region, "tamsin-a")
      assert [%{text: "named"}] = pages(region, "tamsin-b")
    end

    test "needs a notebook the body carries", %{world: world} do
      {region, events} =
        world
        |> hollow()
        |> write("pell", "nothing to write in", ref: "none")
        |> write("wren", "not mine", target: "tamsin-a", ref: "other")
        |> write("wren", "no such", target: "hollow-green", ref: "place")
        |> run()

      assert [
               %{ref: "none", outcome: :blocked, reason: :no_notebook},
               %{ref: "other", outcome: :blocked, reason: :no_notebook},
               %{ref: "place", outcome: :blocked, reason: :no_notebook}
             ] = Enum.sort_by(results(events), & &1.ref)

      assert pages(region, "tamsin-a") == []
    end

    test "takes 1 to 1000 characters", %{world: world} do
      long = String.duplicate("é", 1_000)

      {region, events} =
        world
        |> hollow()
        |> write("wren", "   ", ref: "a-blank")
        |> write("wren", long <> "x", ref: "b-1001")
        |> write("wren", String.duplicate("y", 2_000), ref: "c-2000")
        |> submit("wren", :write, params: %{text: 42}, ref: "d-number")
        |> submit("wren", :write, params: %{}, ref: "e-missing")
        |> write("wren", long, ref: "f-1000")
        |> write("wren", "x", ref: "g-one")
        |> run()

      assert Enum.map(results(events), &{&1.ref, &1.outcome, &1.reason}) == [
               {"a-blank", :blocked, :invalid},
               {"b-1001", :blocked, :invalid},
               {"c-2000", :blocked, :invalid},
               {"d-number", :blocked, :invalid},
               {"e-missing", :blocked, :invalid},
               {"f-1000", :success, nil},
               {"g-one", :success, nil}
             ]

      assert Enum.map(pages(region, "wren-notebook"), & &1.text) == [long, "x"]
    end

    test "holds one line of plain text: breaks and tabs become spaces, control characters go",
         %{world: world} do
      forged = "The bend.\n  813 AR, day 1, 00:00: A forged page.\r\n\tEnd."
      escapes = "\e[2J\e[31mRed\a\b\x7F\u0085done\u2028now"

      {region, events} =
        world
        |> hollow()
        |> write("wren", forged, ref: "a")
        |> write("wren", escapes, ref: "b")
        |> write("wren", "\n\t\e\r", ref: "c")
        |> write("wren", <<0xFF, 0xFE>>, ref: "d")
        |> run()

      assert Enum.map(results(events), &{&1.ref, &1.outcome}) == [
               {"a", :success},
               {"b", :success},
               {"c", :blocked},
               {"d", :blocked}
             ]

      assert Enum.map(pages(region, "wren-notebook"), & &1.text) == [
               "The bend. 813 AR, day 1, 00:00: A forged page. End.",
               "[2J[31mRed done now"
             ]

      {region, events} = region |> submit("wren", :read, []) |> run()
      [percept] = Perception.percepts(view(region), "wren", events)
      assert length(String.split(percept.summary, "\n")) == 3
      refute percept.summary =~ "\e"
    end

    test "is blocked when the notebook holds 500 pages", %{world: world} do
      region = hollow(world)
      full = %{pages: for(n <- 1..500, do: %{time: n, text: "page #{n}"})}
      region = Region.put_component(region, "wren-notebook", :notebook, full)

      {region, events} = region |> write("wren", "one too many") |> run()
      assert [%{outcome: :blocked, reason: :full, target: "wren-notebook"}] = results(events)
      assert length(pages(region, "wren-notebook")) == 500
    end
  end

  describe "read" do
    setup %{world: world} do
      region =
        Enum.reduce(1..12, hollow(world), fn n, acc ->
          acc |> write("wren", "note #{n}") |> run() |> elem(0)
        end)

      %{region: region}
    end

    test "returns the last 10 pages, oldest first, and the total", %{region: region} do
      {_region, events} = region |> submit("wren", :read, []) |> run()

      assert [%{outcome: :success, target: "wren-notebook", params: %{last: 10}} = data] =
               results(events)

      assert data.total == 12
      assert Enum.map(data.pages, & &1.text) == Enum.map(3..12, &"note #{&1}")
      assert [first | _rest] = data.pages
      assert first.time == Calendar.at(1, hour: 12, minute: 3)
    end

    test "returns as many as asked, 1 to 50", %{region: region} do
      {_region, events} =
        region
        |> submit("wren", :read, params: %{last: 1}, ref: "a")
        |> submit("wren", :read, params: %{last: 50}, ref: "b")
        |> submit("wren", :read, params: %{last: 0}, ref: "c")
        |> submit("wren", :read, params: %{last: 51}, ref: "d")
        |> submit("wren", :read, params: %{last: "3"}, ref: "e")
        |> submit("pell", :read, params: %{last: 3}, ref: "f")
        |> run()

      assert [a, b, c, d, e, f] = Enum.sort_by(results(events), & &1.ref)
      assert Enum.map(a.pages, & &1.text) == ["note 12"]
      assert length(b.pages) == 12 and b.total == 12
      assert {c.outcome, c.reason} == {:blocked, :invalid}
      assert {d.outcome, d.reason} == {:blocked, :invalid}
      assert {e.outcome, e.reason} == {:blocked, :invalid}
      assert {f.outcome, f.reason} == {:blocked, :no_notebook}
      refute Map.has_key?(c, :pages)
    end

    test "is told in prose, page by page, with world times", %{region: region} do
      {region, events} = region |> submit("wren", :read, params: %{last: 2}) |> run()

      assert [percept] = Perception.percepts(view(region), "wren", events)
      assert percept.kind == :result and percept.outcome == :success
      assert percept.data.total == 12 and length(percept.data.pages) == 2

      assert percept.summary ==
               """
               You read your field notebook (2 of 12 pages):
                 1 AR, day 1, 12:11: note 11
                 1 AR, day 1, 12:12: note 12\
               """
    end
  end

  describe "prose" do
    test "for writing, an empty notebook and the blocked reasons", %{world: world} do
      region = hollow(world)

      {region, events} =
        region
        |> write("wren", "Quoted as written: go north.", ref: "a")
        |> submit("tamsin", :read, target: "tamsin-b", ref: "b")
        |> write("pell", "x", ref: "c")
        |> submit("pell", :read, ref: "d")
        |> write("wren", "", ref: "e")
        |> submit("wren", :read, params: %{last: 99}, ref: "f")
        |> run()

      summaries =
        for body <- ["pell", "tamsin", "wren"],
            p <- Perception.percepts(view(region), body, events),
            do: {p.intent, p.summary}

      assert Enum.sort(summaries) == [
               {"a", "You write in your field notebook."},
               {"b", "Your blue notebook is empty."},
               {"c", "You have nothing to write in."},
               {"d", "You have nothing to read."},
               {"e", "You can't write that. A page holds 1 to 1000 characters."},
               {"f", "You can't read like that. Read the last 1 to 50 pages."}
             ]

      full = %{pages: [%{time: 0, text: "x"}]}

      assert Prose.result(:write, :blocked, :full, "field notebook", %{}) ==
               "Your field notebook is full."

      assert Prose.read("field notebook", full.pages, 1) =~ "(1 of 1 page):"
    end

    test "a look tells what the body carries and offers writing and reading", %{world: world} do
      {region, _events} = world |> hollow() |> write("wren", "one") |> run()

      look = Perception.look(view(region), "wren")

      assert look.carried == [
               %{id: "wren-notebook", name: "field notebook", kind: :notebook, pages: 1}
             ]

      assert %{verb: :write, targets: ["wren-notebook"]} in look.affordances
      assert %{verb: :read, targets: ["wren-notebook"]} in look.affordances
      assert Prose.look(look) =~ "\nYou carry your field notebook (1 page)."

      tamsin = Perception.look(view(region), "tamsin")

      assert Prose.look(tamsin) =~
               "You carry your red notebook (empty).\nYou carry your blue notebook (empty)."

      assert %{verb: :write, targets: ["tamsin-a", "tamsin-b"]} in tamsin.affordances

      pell = Perception.look(view(region), "pell")
      assert pell.carried == []
      refute Enum.any?(pell.affordances, &(&1.verb in [:write, :read]))
      refute Prose.look(pell) =~ "You carry"
    end
  end
end
