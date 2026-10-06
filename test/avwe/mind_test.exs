defmodule Avwe.MindTest do
  @moduledoc """
  `Avwe.Mind`, the controller side for programs, over a running Lantern
  Hollow at noon with a manual clock stepped from the test. Wren and Tamsin
  stand together on Hollow Green, beside a cold fire pit.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0, eventually: 1]

  alias Avwe.{Mind, Session}

  @world :hollow_minds

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        hearths: [
          [
            id: "fire-pit",
            at: "hollow-green",
            name: "the fire pit",
            fuel_kg: 8.0,
            power_w: 5_000.0
          ]
        ]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)
  end

  # A Mind outlives the test process unless closed: its session's sink is
  # the Mind, not the test.
  defp mind(body, opts \\ []) do
    {:ok, mind} = Mind.start(@world, body, opts)

    on_exit(fn ->
      try do
        Mind.close(mind)
      catch
        :exit, _gone -> :ok
      end
    end)

    mind
  end

  # Waits until the Mind has handled every percept of the steps so far, and
  # submitted any next step of its plan: the session has handled the
  # world's events once it answers a call, and the Mind the session's
  # percepts once it answers one.
  defp settle(mind) do
    %{session: session} = :sys.get_state(mind)
    _body = Session.body(session)
    _state = :sys.get_state(mind)
    :ok
  end

  defp step(mind, steps \\ 1) do
    for _n <- 1..steps do
      Avwe.step(@world, 1)
      settle(mind)
    end

    :ok
  end

  # Calls `act/3` from a task and returns once the Mind is waiting on it,
  # its first step submitted.
  defp acting(mind, steps, opts \\ []) do
    task = Task.async(fn -> Mind.act(mind, steps, opts) end)
    eventually(fn -> :sys.get_state(mind).waiter != nil end)
    task
  end

  defp summaries(report), do: Enum.map(report.percepts, & &1.summary)

  defp say(text), do: {:say, params: %{text: text}}

  describe "act" do
    test "is done when the last step succeeds, and the plan's own results don't interrupt it" do
      wren = mind("wren")
      task = acting(wren, [say("one"), say("two")])
      step(wren, 2)

      assert {:ok, report} = Task.await(task)
      assert report.status == :done
      assert report.plan == [] and report.action == nil and report.dropped == 0
      assert summaries(report) == [~s(You say, "one"), ~s(You say, "two")]
    end

    test "what the body senses of its own doing doesn't interrupt it either" do
      wren = mind("wren")
      # Lighting the fire is sensed before the kindle's result, in the same
      # step. (The smoke it gives off is the world's, and may interrupt.)
      task = acting(wren, {:kindle, []})
      step(wren)

      assert {:ok, %{status: :done} = report} = Task.await(task)
      assert [%{type: :fire_lit, issuer: :controller}, %{kind: :result}] = report.percepts
      assert "You light the fire pit." in summaries(report)
    end

    test "has failed when a step does not succeed, and the rest of the plan is dropped" do
      wren = mind("wren")
      task = acting(wren, [{:go, target: "atlantis"}, say("never")])
      step(wren, 3)

      assert {:ok, %{status: :failed, plan: [], action: nil} = report} = Task.await(task)
      assert summaries(report) == ["You don't know the way there."]

      step(wren, 2)
      assert {:ok, %{status: :idle, percepts: []}} = Mind.percepts(wren)
    end

    test "is interrupted when someone speaks to the body, and the wait goes on" do
      wren = mind("wren")
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")

      task = acting(wren, {:wait, params: %{for: 60 * 60}})
      step(wren, 2)
      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Wren, look at the pond."})
      step(wren)

      assert {:ok, report} = Task.await(task)
      assert report.status == :interrupted
      assert %{verb: :wait} = report.action
      assert List.last(summaries(report)) == ~s(Tamsin says, "Wren, look at the pond.")

      assert {:ok, %{action: %{verb: :wait}}} = Mind.look(wren)
      step(wren, 5)
      assert {:ok, %{status: :still_going, percepts: []}} = Mind.percepts(wren)
    end

    test "only what reaches interrupt_at interrupts" do
      wren = mind("wren")
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")

      task = acting(wren, {:wait, params: %{for: 5 * 60}}, interrupt_at: 0.95)
      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Quietly now."})
      step(wren, 5)

      assert {:ok, %{status: :done} = report} = Task.await(task)
      assert ~s(Tamsin says, "Quietly now.") in summaries(report)
    end

    test "is still going when max_wait_ms passes; the next call shows it finishing" do
      wren = mind("wren")

      assert {:ok, report} = Mind.act(wren, {:wait, params: %{for: 10 * 60}}, max_wait_ms: 50)
      assert report.status == :still_going
      assert %{verb: :wait, ref: "i-" <> _n} = report.action

      step(wren, 10)
      assert {:ok, %{status: :done, action: nil} = report} = Mind.percepts(wren)
      assert List.last(summaries(report)) == "You finish waiting."
    end

    test "keeps running the plan between calls" do
      wren = mind("wren")
      plan = [{:wait, params: %{for: 60}}, say("first"), say("second")]

      assert {:ok, report} = Mind.act(wren, plan, max_wait_ms: 0)
      assert report.status == :still_going
      assert report.plan == [say("first"), say("second")]

      step(wren, 4)

      assert {:ok, %{status: :done, plan: []} = report} = Mind.percepts(wren)

      assert summaries(report) == [
               "You settle in to wait.",
               "You finish waiting.",
               ~s(You say, "first"),
               ~s(You say, "second")
             ]
    end

    test "a call made while another waits answers the waiting one first" do
      wren = mind("wren")
      waiting = acting(wren, {:wait, params: %{for: 60 * 60}})
      step(wren)

      assert {:ok, %{status: :still_going, action: %{verb: :wait}}} = Mind.percepts(wren)
      assert {:ok, %{status: :still_going}} = Task.await(waiting)
    end

    test "refuses the session's own verbs, autopilot's refs and what is not a plan" do
      wren = mind("wren")

      assert {:error, :reserved} = Mind.act(wren, [say("no"), {:release, []}])
      assert {:error, :reserved} = Mind.act(wren, {:control})
      assert {:error, :reserved} = Mind.act(wren, {:say, params: %{text: "x"}, ref: "auto-1"})
      assert {:error, :invalid_ref} = Mind.act(wren, {:say, ref: 7})
      assert {:error, :invalid_plan} = Mind.act(wren, [])
      assert {:error, :invalid_plan} = Mind.act(wren, "say hello")
      assert {:error, :invalid_options} = Mind.act(wren, say("x"), max_wait_ms: -1)

      step(wren, 2)
      assert {:ok, %{percepts: []}} = Mind.percepts(wren)
    end
  end

  describe "stop" do
    test "drops the plan, stops the action and waits for the stop's result" do
      wren = mind("wren")
      waiting = acting(wren, [{:wait, params: %{for: 60 * 60}}, say("never")])
      step(wren)

      stopping = Task.async(fn -> Mind.stop(wren) end)
      assert {:ok, %{status: :still_going}} = Task.await(waiting)
      eventually(fn -> :sys.get_state(wren).waiter != nil end)
      step(wren)

      assert {:ok, %{status: :done, plan: [], action: nil} = report} = Task.await(stopping)
      assert summaries(report) == ["You stop waiting.", nil]

      step(wren, 3)
      assert {:ok, %{percepts: []}} = Mind.percepts(wren)
    end
  end

  describe "percepts" do
    test "returns and clears what was perceived, keeping the newest 500" do
      wren = mind("wren")
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")
      for n <- 1..600, do: {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "#{n}"})
      step(wren)

      assert {:ok, %{status: :idle, dropped: 100} = report} = Mind.percepts(wren)
      assert length(report.percepts) == 500
      assert hd(summaries(report)) == ~s(Tamsin says, "101")
      assert List.last(summaries(report)) == ~s(Tamsin says, "600")

      assert {:ok, %{percepts: [], dropped: 0}} = Mind.percepts(wren)
    end
  end

  describe "look" do
    test "tells what happened while nobody held the body, on the first look only" do
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")
      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Is anyone there?"})
      Avwe.step(@world, 2)

      wren = mind("wren")
      step(wren, 2)

      assert {:ok, %{away: [%{summary: ~s(Tamsin says, "Is anyone there?")}]}} = Mind.look(wren)
      assert {:ok, %{away: [], body: %{id: "wren"}}} = Mind.look(wren)
    end
  end

  describe "the body" do
    test "is taken while the Mind runs, and given back when it closes" do
      wren = mind("wren", controller: :arbor)
      assert Mind.body(wren) == "wren"
      assert {:error, :body_taken} = Mind.start(@world, "wren")
      assert {:error, :invalid_controller} = Mind.start(@world, "tamsin", controller: :human)
      assert {:error, :no_such_body} = Mind.start(@world, "ghost")

      step(wren)
      assert holder("wren") == :arbor

      Mind.close(wren)
      eventually(fn -> not taken?("wren") end)
      Avwe.step(@world, 1)
      assert holder("wren") == nil
    end

    test "is given back when nobody calls for quit_after" do
      wren = mind("wren", quit_after: 50)
      ref = Process.monitor(wren)

      assert_receive {:DOWN, ^ref, :process, ^wren, :normal}, 1_000
      eventually(fn -> not taken?("wren") end)
    end

    test "calls keep it from quitting" do
      wren = mind("wren", quit_after: 500)

      for _n <- 1..6 do
        Process.sleep(150)
        assert {:ok, _report} = Mind.percepts(wren)
      end

      assert Process.alive?(wren)
    end
  end

  defp taken?(body) do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == body)).taken
  end

  defp holder(body) do
    {:ok, snapshot} = Avwe.snapshot(@world)
    snapshot.components.control[body].holder
  end
end
