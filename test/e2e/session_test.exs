defmodule Avwe.E2E.SessionTest do
  @moduledoc """
  End to end through `Avwe.Session`, the API every controller (telnet, MCP,
  Arbor) uses. Runs Lantern Hollow at noon with a manual clock, with a fire
  pit on Hollow Green and a wind from the north.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures

  alias Avwe.{Percept, Session}

  @world :hollow_sessions
  @fire_pit [
    id: "green-fire-pit",
    at: "hollow-green",
    name: "the fire pit on the green",
    fuel_kg: 8.0,
    power_w: 5_000.0
  ]

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        hearths: [@fire_pit],
        climate: [wind: [from: "north", m_s: 2.0]]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)
  end

  defp join(body) do
    {:ok, session} = Avwe.connect(@world, body: body, controller: :arbor)
    session
  end

  defp results(percepts), do: Enum.filter(percepts, &(&1.kind == :result))

  describe "acting" do
    test "an intent's result comes back with its ref and an Arbor outcome" do
      wren = join("wren")

      {:ok, ref} = Session.act(wren, :go, target: "mill-pond")
      Avwe.step(@world, 2)

      assert [
               %Percept{
                 kind: :progress,
                 type: :action_started,
                 intent: ^ref,
                 summary: "You set off toward Mill Pond."
               },
               %Percept{
                 kind: :result,
                 intent: ^ref,
                 outcome: :success,
                 summary: "You arrive at Mill Pond."
               }
             ] = percepts(wren)

      assert {:ok, %{here: %{name: "Mill Pond"}}} = Session.look(wren)
    end

    test "callers can choose the ref" do
      wren = join("wren")
      assert {:ok, "plan-7"} = Session.act(wren, :wait, params: %{for: 60}, ref: "plan-7")

      Avwe.step(@world, 1)
      assert [%Percept{intent: "plan-7", outcome: :success}] = wren |> percepts() |> results()
    end

    test "every intent gets exactly one result, whatever happens to it" do
      odo = join("odo")

      {:ok, walk} = Session.act(odo, :go, target: "hollow-green")
      {:ok, _} = Session.act(odo, :go, target: "nowhere")
      {:ok, _} = Session.act(odo, :say, params: %{text: ""})
      {:ok, _} = Session.act(odo, :juggle)
      Avwe.step(@world, 3)

      {:ok, _} = Session.act(odo, :stop)
      {:ok, _} = Session.act(odo, :wait, params: %{for: 600})
      Avwe.step(@world, 15)

      refs = odo |> percepts() |> results() |> Enum.map(& &1.intent)
      assert Enum.sort(refs) == Enum.map(1..6, &"i-#{&1}")
      assert walk == "i-1"
    end

    test "spectators can't act" do
      {:ok, watcher} = Avwe.connect(@world)
      assert Session.act(watcher, :say, params: %{text: "hello"}) == {:error, :spectator}
    end
  end

  describe "perceiving" do
    setup do
      %{wren: join("wren"), tamsin: join("tamsin"), pell: join("pell"), odo: join("odo")}
    end

    test "talk reaches the green but not the pond or the tower", bodies do
      Session.act(bodies.wren, :say, params: %{text: "Good morning"})
      Avwe.step(@world, 1)

      assert ~s(You say, "Good morning") in summaries(bodies.wren)

      assert [
               %Percept{kind: :sensed, modality: :hearing, source: %{ref: "wren", distance_m: 0}} =
                 heard
             ] = percepts(bodies.tamsin)

      assert heard.summary == ~s(Wren says, "Good morning")
      assert percepts(bodies.pell) == []
      assert percepts(bodies.odo) == []
    end

    test "a shout reaches the pond, with a direction, but not the tower", bodies do
      Session.act(bodies.wren, :say, params: %{text: "Fire at the mill!", volume: :shout})
      Avwe.step(@world, 1)

      assert [%Percept{source: %{distance_m: 70, direction: "west"}, salience: salience} = heard] =
               percepts(bodies.pell)

      assert heard.summary == ~s(Wren shouts from the west, "Fire at the mill!")
      assert salience > 0.5
      assert percepts(bodies.odo) == []
    end

    test "others see a body leave and arrive", bodies do
      Session.act(bodies.odo, :go, target: "hollow-green")
      Avwe.step(@world, 25)

      assert "Odo arrives at Hollow Green." in summaries(bodies.wren)
      assert "Odo arrives at Hollow Green." in summaries(bodies.pell)
      assert "You arrive at Hollow Green." in summaries(bodies.odo)

      {:ok, look} = Session.look(bodies.odo)

      assert look.bodies |> Enum.filter(& &1.here) |> Enum.map(& &1.name) |> Enum.sort() == [
               "Tamsin",
               "Wren"
             ]
    end

    test "a spectator perceives the whole world", bodies do
      {:ok, watcher} = Avwe.connect(@world)

      Session.act(bodies.odo, :say, params: %{text: "All quiet."})
      Avwe.step(@world, 1)

      assert [~s(Odo says, "All quiet.")] = summaries(watcher)
      assert {:ok, %{spectator: true, bodies: bodies}} = Session.look(watcher)
      assert length(bodies) == 4
    end
  end

  describe "fire" do
    test "kindling succeeds, and a body 300 m downwind smells the smoke" do
      wren = join("wren")
      tamsin = join("tamsin")
      pell = join("pell")

      {:ok, _walk} = Session.act(tamsin, :walk, params: %{direction: "south", distance_m: 300})
      Avwe.step(@world, 5)
      assert "You stop, 300 m south of where you set out." in summaries(tamsin)

      {:ok, ref} = Session.act(wren, :kindle)
      Avwe.step(@world, 5)

      assert [%Percept{intent: ^ref, outcome: :success, summary: nil}] =
               wren |> percepts() |> results()

      assert [%Percept{kind: :sensed, type: :smoke_smelled, modality: :smell, summary: smelled}] =
               Enum.filter(percepts(tamsin), &(&1.type == :smoke_smelled))

      assert smelled =~ ~r/^You smell woodsmoke.* from the north\.$/
      refute Enum.any?(percepts(pell), &(&1.modality == :smell))
    end
  end

  describe "leases" do
    test "only one session can control a body" do
      _wren = join("wren")
      assert Avwe.connect(@world, body: "wren") == {:error, :body_taken}
      assert %{taken: true} = Enum.find(elem(Avwe.bodies(@world), 1), &(&1.id == "wren"))
    end

    test "the body is released when the controller goes away" do
      sink = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _session} = Avwe.connect(@world, body: "wren", sink: sink)
      assert Avwe.connect(@world, body: "wren") == {:error, :body_taken}

      Process.exit(sink, :kill)
      eventually(fn -> match?({:ok, _session}, Avwe.connect(@world, body: "wren")) end)
    end

    test "closing a session releases the body" do
      wren = join("wren")
      :ok = Session.close(wren)
      assert {:ok, _session} = Avwe.connect(@world, body: "wren")
    end

    test "connecting fails clearly" do
      assert Avwe.connect(:no_such_world, body: "wren") == {:error, :no_such_world}
      assert Avwe.connect(@world, body: "nobody") == {:error, :no_such_body}
    end
  end
end
