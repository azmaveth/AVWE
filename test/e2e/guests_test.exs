defmodule Avwe.E2E.GuestsTest do
  @moduledoc """
  End to end through `Avwe.Session`: a controller arrives in Lantern Hollow as
  a guest of its own making. The world is at noon on a manual clock, takes two
  guests, and has Wren on Hollow Green, where they arrive.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures

  alias Avwe.{Percept, Session}

  @world :hollow_guests
  @tomas [name: "Tomas Reed", backstory: "A salvage diver from Willow Docks."]
  @ines [name: "Ines Cole", backstory: nil]

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        guests: [arrival: "hollow-green", max: 2]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)
  end

  defp arrive(guest, opts \\ []) do
    Avwe.connect(@world, [guest: guest, controller: :mcp] ++ opts)
  end

  defp arrived(guest) do
    {:ok, session} = arrive(guest)
    Avwe.step(@world, 1)
    :ok = Session.await_arrival(session, 1_000)
    session
  end

  defp lease(id), do: Registry.lookup(Avwe.Registry, {:lease, @world, id})

  describe "arriving" do
    test "makes the body at the next step; until then the session is arriving" do
      {:ok, tomas} = arrive(@tomas)

      assert Session.body(tomas) == "guest-tomas-reed"
      assert {:error, :arriving} = Session.look(tomas)
      assert {:error, :arriving} = Session.peek(tomas)
      assert {:ok, bodies} = Avwe.bodies(@world)
      refute Enum.any?(bodies, &(&1.id == "guest-tomas-reed"))

      Avwe.step(@world, 1)

      assert :ok = Session.await_arrival(tomas, 1_000)

      assert {:ok,
              %{
                body: %{id: "guest-tomas-reed", name: "Tomas Reed"},
                here: %{name: "Hollow Green"}
              } = look} =
               Session.look(tomas)

      assert look.holder == :mcp
      assert look.away == []
    end

    test "can be waited for while the world is stepped from elsewhere" do
      {:ok, tomas} = arrive(@tomas)
      waiting = Task.async(fn -> Session.await_arrival(tomas, 5_000) end)

      Process.sleep(50)
      refute Task.yield(waiting, 0)
      Avwe.step(@world, 1)

      assert Task.await(waiting) == :ok
    end

    test "gives up waiting when the world is not stepped" do
      {:ok, tomas} = arrive(@tomas)
      assert {:error, :timeout} = Session.await_arrival(tomas, 50)

      # The arrival is still on its way: the world has only not stepped.
      Avwe.step(@world, 1)
      assert :ok = Session.await_arrival(tomas, 1_000)
    end

    test "is waited for by a body that is there already as nothing" do
      {:ok, wren} = Avwe.connect(@world, body: "wren", controller: :mcp)
      assert :ok = Session.await_arrival(wren, 10)
    end

    test "is seen by those in sight, who are told as of anyone who arrives" do
      {:ok, wren} = Avwe.connect(@world, body: "wren", controller: :mcp)
      _tomas = arrived(@tomas)

      assert "Tomas Reed arrives at Hollow Green." in summaries(wren)
    end

    test "is not told to the guest as a result: the arrival is the session's own" do
      tomas = arrived(@tomas)
      assert percepts(tomas) == []

      {:ok, ref} = Session.act(tomas, :wait, params: %{for: 60})
      Avwe.step(@world, 1)
      assert [%Percept{intent: ^ref}, %Percept{intent: ^ref}] = percepts(tomas)
    end

    test "does not perceive the steps before its body exists, which a session hears of from the start" do
      {:ok, _wren} = Avwe.connect(@world, body: "wren", controller: :mcp)
      {:ok, tomas} = arrive(@tomas)
      {:ok, snapshot} = Avwe.snapshot(@world)

      speech =
        Avwe.Event.new(:speech,
          entity: "wren",
          time: snapshot.time,
          data: %{text: "Hello.", volume: :talk, position: snapshot.components.position["wren"]}
        )

      view = Map.take(snapshot, [:id, :step, :time, :components, :env])
      send(tomas, {:avwe_events, @world, [speech], view})

      # The session answers a call once it has handled the message, and lives.
      assert Session.body(tomas) == "guest-tomas-reed"
      assert Process.alive?(tomas)
      assert percepts(tomas) == []
    end

    test "is for the controller that asks, and no other: the verb is not one to ask for" do
      tomas = arrived(@tomas)
      assert {:error, :reserved} = Session.act(tomas, :arrive, params: %{name: "Ines Cole"})
    end

    test "can write in its notebook, which a later controller of the body can read" do
      tomas = arrived(@tomas)

      {:ok, _ref} = Session.act(tomas, :write, params: %{text: "The well is deep."})
      Avwe.step(@world, 1)
      Session.close(tomas)

      assert {:ok, again} = Avwe.connect(@world, body: "guest-tomas-reed", controller: :arbor)
      {:ok, ref} = Session.act(again, :read)
      Avwe.step(@world, 1)

      assert %Percept{outcome: :success, data: %{pages: [%{text: "The well is deep."}]}} =
               again |> percepts() |> Enum.find(&(&1.intent == ref))
    end
  end

  describe "being a guest" do
    test "is listed as one, held, and free again when let go, where it stands" do
      tomas = arrived(@tomas)

      assert {:ok, bodies} = Avwe.bodies(@world)

      assert %{
               guest: true,
               taken: true,
               controller: :mcp,
               name: "Tomas Reed",
               description: "A guest."
             } =
               Enum.find(bodies, &(&1.id == "guest-tomas-reed"))

      assert %{guest: false} = Enum.find(bodies, &(&1.id == "wren"))

      Session.close(tomas)
      Avwe.step(@world, 1)

      assert eventually(fn ->
               {:ok, bodies} = Avwe.bodies(@world)

               match?(
                 %{taken: false, controller: :autopilot},
                 Enum.find(bodies, &(&1.id == "guest-tomas-reed"))
               )
             end)
    end

    test "is taken back like any free body" do
      tomas = arrived(@tomas)
      Session.close(tomas)
      Avwe.step(@world, 1)
      assert eventually(fn -> lease("guest-tomas-reed") == [] end)

      assert {:ok, again} = Avwe.connect(@world, body: "guest-tomas-reed", controller: :arbor)
      assert {:ok, %{body: %{name: "Tomas Reed"}}} = Session.look(again)
    end
  end

  describe "refusing" do
    test "a name another is arriving under or is, which holds no lease for the refused" do
      {:ok, _tomas} = arrive(@tomas)

      assert {:error, :name_taken} = arrive(name: "tomas  reed")
      assert {:error, :name_taken} = arrive(name: "Wren")
      assert {:error, :name_taken} = arrive(name: "Hollow Green")

      Avwe.step(@world, 1)
      assert {:error, :name_taken} = arrive(name: "Tomás Reed")
      assert lease("guest-wren") == []
    end

    test "an arrival past the most the world takes, even before the others have arrived" do
      {:ok, _tomas} = arrive(@tomas)
      {:ok, _ines} = arrive(@ines)

      assert {:error, :full} = arrive(name: "Pim Aldous")
      assert lease("guest-pim-aldous") == []

      Avwe.step(@world, 1)
      assert {:error, :full} = arrive(name: "Pim Aldous")
    end

    test "a name that is not a name, and a backstory that is not one" do
      assert {:error, :invalid_name} = arrive(name: "x")
      assert {:error, :invalid_name} = arrive(name: "Tomas <script>")
      assert {:error, :invalid_name} = arrive(name: "someone")
      assert {:error, :invalid_name} = arrive(backstory: "no name")
      assert {:error, :invalid_name} = arrive("Tomas Reed")

      assert {:error, :invalid_backstory} =
               arrive(name: "Tomas Reed", backstory: String.duplicate("b", 1_001))
    end

    test "a body and a guest together" do
      assert {:error, :body_and_guest} = arrive(@tomas, body: "wren")
    end

    test "a world that takes no guests" do
      {:ok, _pid} =
        Avwe.start_world(:hollow_no_guests, quire: lantern_hollow(), start: {1, hour: 12})

      on_exit(fn -> Avwe.stop_world(:hollow_no_guests) end)

      assert {:error, :no_guests} =
               Avwe.connect(:hollow_no_guests, guest: @tomas, controller: :mcp)
    end

    test "a world that is not running" do
      assert {:error, :no_such_world} = Avwe.connect(:nowhere, guest: @tomas, controller: :mcp)
    end
  end

  describe "the settings of a world" do
    test "are part of what it says of itself" do
      assert {_id, %{guests: %{arrival: "hollow-green", max: 2}}} =
               Enum.find(Avwe.worlds(), fn {id, _info} -> id == @world end)
    end

    test "are checked when the world starts" do
      for guests <- [
            [arrival: "atlantis", max: 2],
            [arrival: "hollow-green", max: 0],
            [arrival: "hollow-green"],
            [max: 2],
            "wren"
          ] do
        assert_raise ArgumentError, ~r/guests/, fn ->
          Avwe.start_world(:hollow_bad_guests,
            quire: lantern_hollow(),
            start: {1, hour: 12},
            guests: guests
          )
        end
      end
    end
  end
end
