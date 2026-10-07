defmodule Avwe.MindTest do
  @moduledoc """
  `Avwe.Mind`, the controller side for programs, over a running Lantern
  Hollow at noon with a manual clock stepped from the test. Wren and Tamsin
  stand together on Hollow Green, beside a cold fire pit.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures,
    only: [lantern_hollow: 0, ember_reach_opts: 1, eventually: 1, eventually: 2]

  alias Avwe.{Mind, Session}
  alias Avwe.Test.Idle

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

  defp stopped(mind) do
    task = Task.async(fn -> Mind.stop(mind) end)
    eventually(fn -> :sys.get_state(mind).waiter != nil end)
    step(mind)
    Task.await(task)
  end

  defp say(text), do: {:say, params: %{text: text}}

  # Douses the fire pit through the Mind and lets its smoke clear.
  defp stopped_fire(mind) do
    task = acting(mind, {:douse, []})
    step(mind)
    {:ok, report} = Task.await(task)
    report
  end

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
      # step, and so is its smoke, which is her own fire's.
      task = acting(wren, {:kindle, []})
      step(wren)

      assert {:ok, %{status: :done} = report} = Task.await(task)

      assert [
               %{type: :fire_lit, issuer: :controller},
               %{kind: :result},
               %{type: :smoke_smelled, data: %{own_fire: true}, source: %{ref: "fire-pit"}}
             ] = report.percepts

      assert "You light the fire pit." in summaries(report)
    end

    test "the smoke of the body's own fire doesn't interrupt; a stranger's does" do
      wren = mind("wren")
      task = acting(wren, [{:kindle, []}, {:wait, params: %{for: 10 * 60}}])
      step(wren, 11)

      assert {:ok, %{status: :done} = report} = Task.await(task)
      assert Enum.any?(report.percepts, &(&1.type == :smoke_smelled and &1.salience >= 0.6))
      assert List.last(summaries(report)) == "You finish waiting."
      assert %{status: :done} = stopped_fire(wren)

      # Tamsin lights it this time: the smoke Wren smells is not hers.
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")
      step(wren, 30)
      task = acting(wren, {:wait, params: %{for: 60 * 60}})
      {:ok, _ref} = Session.act(tamsin, :kindle)
      step(wren)

      assert {:ok, %{status: :interrupted} = report} = Task.await(task)
      assert %{type: :smoke_smelled, data: nil} = List.last(report.percepts)
      assert %{verb: :wait} = report.action
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
      assert %{verb: :wait, ref: "m-" <> _n} = report.action

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

  describe "refs" do
    test "are the Mind's own: a result for an earlier holder's ref settles nothing" do
      # A telnet-style session left Wren on a long wait under its first ref.
      {:ok, before} = Avwe.connect(@world, body: "wren")
      assert {:ok, "i-1"} = Session.act(before, :wait, params: %{for: 60 * 60})
      Avwe.step(@world, 1)
      :ok = Session.close(before)

      wren = mind("wren")
      task = acting(wren, {:wait, params: %{for: 5 * 60}})
      # Her new wait replaces the old one, whose result (ref i-1) comes in
      # the same step.
      step(wren)
      assert Task.yield(task, 50) == nil
      step(wren, 5)

      assert {:ok, %{status: :done, action: nil} = report} = Task.await(task)

      assert [%{intent: "i-1", outcome: :interrupted}, %{intent: "m-" <> _n} = own] =
               Enum.filter(report.percepts, &(&1.kind == :result))

      assert own.outcome == :success
    end

    test "a caller's ref is only a label: the same one twice is no collision" do
      wren = mind("wren")
      plan = [{:wait, params: %{for: 60}, ref: "x"}, {:say, params: %{text: "hi"}, ref: "x"}]
      assert {:ok, %{status: :still_going, action: action}} = Mind.act(wren, plan, max_wait_ms: 0)
      assert %{ref: "m-" <> _n, label: "x", verb: :wait} = action

      step(wren, 3)
      assert {:ok, %{status: :done} = report} = Mind.percepts(wren)
      results = Enum.filter(report.percepts, &(&1.kind == :result))
      assert [%{intent: first}, %{intent: second}] = results
      assert first != second
      assert List.last(summaries(report)) == ~s(You say, "hi")
    end

    test "are random, not a count that starts again when the server does" do
      wren = mind("wren")
      plan = [{:wait, params: %{for: 60}}, {:wait, params: %{for: 60}}]
      assert {:ok, %{status: :still_going}} = Mind.act(wren, plan, max_wait_ms: 0)
      step(wren, 2)
      assert {:ok, %{status: :done} = report} = Mind.percepts(wren)
      assert [first, second] = for(%{kind: :result, intent: ref} <- report.percepts, do: ref)

      assert first =~ ~r/^m-[A-Za-z0-9_-]{12}$/
      assert second =~ ~r/^m-[A-Za-z0-9_-]{12}$/
      assert first != second
    end
  end

  describe "names" do
    test "a step's target is named and resolved when the step is submitted, not when sent" do
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")
      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Pell!", volume: :shout})
      Avwe.step(@world, 1)

      # At the Mill Pond, 70 m off, no hearth is in reach of Pell.
      pell = mind("pell")

      plan = [
        {:go, target_name: "hollow green"},
        {:kindle, target_name: "the fire pit"},
        {:douse, target: "Fire Pit"}
      ]

      task = acting(pell, plan, max_wait_ms: 5_000)

      report =
        Enum.reduce_while(1..20, nil, fn _n, nil ->
          step(pell)

          case Task.yield(task, 20) do
            {:ok, {:ok, report}} -> {:halt, report}
            nil -> {:cont, nil}
          end
        end)

      assert %{status: :done} = report
      results = Enum.filter(report.percepts, &(&1.kind == :result))
      assert ["You arrive at Hollow Green." | _rest] = Enum.map(results, & &1.summary)
      assert "You light the fire pit." in summaries(report)
      assert "You douse the fire pit." in summaries(report)

      # Looking for itself kept the first look's news for the program.
      assert {:ok, %{away: away}} = Mind.look(pell)
      assert ~s(Tamsin shouts from the west, "Pell!") in Enum.map(away, & &1.summary)
    end

    test "a name that could mean more than one thing is not submitted" do
      wren = mind("wren")

      assert {:error, {:ambiguous, "o", ["Far Tower", "Hollow Green", "Mill Pond"]}} =
               Mind.act(wren, {:go, target_name: "o"})

      task = acting(wren, [{:wait, params: %{for: 60}}, {:go, target_name: "o"}, {:stop, []}])
      step(wren, 2)

      assert {:ok, %{status: :failed} = report} = Task.await(task)
      assert report.problem == {:ambiguous, "o", ["Far Tower", "Hollow Green", "Mill Pond"]}
      assert [{:go, _opts}, {:stop, []}] = report.abandoned
      assert report.plan == []

      # The next reply starts clean.
      assert {:ok, %{problem: nil, abandoned: []}} = Mind.percepts(wren)
    end

    test "a name that resolves to nothing is the world's to refuse" do
      wren = mind("wren")
      task = acting(wren, {:kindle, target_name: "the moon"})
      step(wren)

      assert {:ok, %{status: :failed} = report} = Task.await(task)
      assert [%{kind: :result, outcome: :blocked, reason: :no_such_hearth}] = report.percepts
    end
  end

  describe "waiting" do
    test "a caller that waits is present: the body is not yielded under it" do
      # The window is a minute, so no real idle timer goes off in this test:
      # the ones that matter are fired by hand. (A window of a few hundred ms
      # is lost to a late mark when the machine is busy.)
      window = 60_000
      wren = mind("wren", idle_after: window)
      %{session: session, presence_every: every} = :sys.get_state(wren)

      # The Mind marks presence at least twice a window, so a late mark still
      # lands inside it. Here it is asked to mark every 10 ms instead, so that
      # the test can watch it keep marking.
      assert every * 2 <= window
      :sys.replace_state(wren, &%{&1 | presence_every: 10})
      task = acting(wren, {:wait, params: %{for: 60 * 60}})

      # Each mark arms a new idle timer in the session, so the one that was
      # running goes off too late to take the body.
      for _n <- 1..3 do
        running = Idle.timer(session)
        eventually(fn -> Idle.timer(session) != running end, 5_000)
        Idle.fire(session, running)
        refute Idle.yielded?(session)
      end

      # A call made while one waits answers it, as if its wait had run out.
      assert {:ok, %{status: :still_going}} = Mind.percepts(wren)
      assert {:ok, %{status: :still_going} = report} = Task.await(task)
      refute "You let your routine carry you." in summaries(report)

      step(wren)
      assert holder("wren") == :mcp
    end

    test "every step the Mind submitted is followed, not only the plan's current one" do
      wren = mind("wren")

      assert {:ok, %{status: :still_going}} =
               Mind.act(wren, {:wait, params: %{for: 60 * 60}}, max_wait_ms: 0)

      # A new plan before the wait has started: the wait is no longer the
      # plan's, but it is still the Mind's.
      task = acting(wren, say("hi"))
      step(wren)

      assert {:ok, %{status: :done, plan: [], action: %{verb: :wait}}} = Task.await(task)
      assert {:ok, %{status: :still_going, action: %{verb: :wait}}} = Mind.percepts(wren)
    end

    test "a whole step's percepts are in the answer it ends: a discovery with an arrival" do
      {:ok, _pid} =
        Avwe.start_world(:ember_minds, ember_reach_opts(start: {813, day: 220, hour: 8}))

      on_exit(fn -> Avwe.stop_world(:ember_minds) end)
      {:ok, mira} = Mind.start(:ember_minds, "mira-vale")
      on_exit(fn -> Mind.close(mira) end)

      plan = [{:go, target: "the-dry-bend"}, {:follow, params: %{direction: :upstream}}]
      task = Task.async(fn -> Mind.act(mira, plan, max_wait_ms: 20_000) end)
      eventually(fn -> :sys.get_state(mira).waiter != nil end)

      report =
        Enum.reduce_while(1..200, nil, fn _n, nil ->
          Avwe.step(:ember_minds, 1)
          settle(mira)

          case Task.yield(task, 20) do
            {:ok, {:ok, report}} -> {:halt, report}
            nil -> {:cont, nil}
          end
        end)

      assert report.status == :done
      assert [arrived, found] = Enum.take(report.percepts, -2)
      assert %{kind: :result, outcome: :success} = arrived
      assert %{type: :discovered, summary: summary} = found
      assert summary =~ "The Source"
      assert arrived.time == found.time
    end
  end

  describe "the body's own doing" do
    test "an instant step during a durative one is done, and the action still shows" do
      wren = mind("wren")

      assert {:ok, %{status: :still_going}} =
               Mind.act(wren, {:wait, params: %{for: 60 * 60}}, max_wait_ms: 0)

      step(wren)

      task = acting(wren, say("hi"))
      step(wren)

      assert {:ok, %{status: :done, plan: []} = report} = Task.await(task)
      assert %{verb: :wait, ref: "m-" <> _n = ref} = report.action
      assert {:ok, %{action: %{verb: :wait, ref: ^ref}}} = Mind.look(wren)

      step(wren)
      assert {:ok, %{status: :still_going, action: %{verb: :wait}}} = Mind.percepts(wren)

      assert {:ok, %{status: :done, action: nil}} = stopped(wren)
      assert {:ok, %{status: :idle, action: nil}} = Mind.percepts(wren)
    end
  end

  describe "a caller that goes away" do
    test "is forgotten, and what it would have been told waits for the next call" do
      wren = mind("wren")
      {:ok, tamsin} = Avwe.connect(@world, body: "tamsin")

      caller =
        spawn(fn -> Mind.act(wren, {:wait, params: %{for: 60 * 60}}, max_wait_ms: 5_000) end)

      eventually(fn -> :sys.get_state(wren).waiter != nil end)
      step(wren)
      Process.exit(caller, :kill)
      eventually(fn -> :sys.get_state(wren).waiter == nil end)

      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Wren, the pond!"})
      step(wren, 2)

      assert {:ok, %{status: :still_going} = report} = Mind.percepts(wren)
      assert summaries(report) == ["You settle in to wait.", ~s(Tamsin says, "Wren, the pond!")]
    end

    test "doesn't keep the Mind from quitting" do
      wren = mind("wren", quit_after: 100)
      monitor = Process.monitor(wren)

      caller =
        spawn(fn -> Mind.act(wren, {:wait, params: %{for: 60 * 60}}, max_wait_ms: 10_000) end)

      eventually(fn -> :sys.get_state(wren).waiter != nil end)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^wren, :normal}, 1_000
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

    test "is the routine's when the session yields it; the plan ends there, yielded" do
      wren = mind("wren", idle_after: 100)
      plan = [{:go, target: "far-tower"}, {:wait, params: %{for: 60 * 60}}]
      assert {:ok, %{status: :still_going}} = Mind.act(wren, plan, max_wait_ms: 0)
      step(wren)

      %{session: session} = :sys.get_state(wren)
      eventually(fn -> :sys.get_state(session).yielded end)
      step(wren)

      # Nothing failed: the routine took the body back. The journey is
      # still the body's doing, and goes on.
      assert {:ok, %{status: :yielded, plan: [], action: %{verb: :go}} = report} =
               Mind.percepts(wren)

      assert "You let your routine carry you." in summaries(report)
      refute Enum.any?(report.percepts, &(&1.kind == :result))

      # It arrives under the routine; nothing more is submitted, so the
      # body stays the routine's, and the journey's own result is told.
      step(wren, 40)

      assert holder("wren") == nil
      assert %{plan: [], current: nil, doing: nil, pending: pending} = :sys.get_state(wren)
      assert pending == %{}
      assert {:ok, %{status: :idle, plan: [], action: nil} = report} = Mind.percepts(wren)

      assert [%{kind: :result, outcome: :success, summary: "You arrive at Far Tower."}] =
               Enum.filter(report.percepts, &(&1.kind == :result and &1.issuer == :controller))

      refute "You settle in to wait." in summaries(report)
    end

    test "is let go when its world stops, and can be taken again when it starts" do
      wren = mind("wren")
      monitor = Process.monitor(wren)
      step(wren)

      :ok = Avwe.stop_world(@world)
      assert_receive {:DOWN, ^monitor, :process, ^wren, :normal}, 1_000

      {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
      assert {:ok, _taken} = Avwe.connect(@world, body: "wren")
    end

    test "each call re-arms one quit timer, cancelling the one before" do
      wren = mind("wren")
      %{quit_timer: first} = :sys.get_state(wren)
      assert is_integer(Process.read_timer(first))

      assert {:ok, _report} = Mind.percepts(wren)
      %{quit_timer: second} = :sys.get_state(wren)
      assert second != first
      assert Process.read_timer(first) == false
      assert is_integer(Process.read_timer(second))
    end

    test "closing a Mind that has already ended is no error" do
      wren = mind("wren")
      assert :ok = Mind.close(wren)
      assert :ok = Mind.close(wren)
    end

    test "calls keep it from quitting" do
      wren = mind("wren")

      # Each call arms a new quit, so the one that was due goes off too late.
      for _n <- 1..6 do
        %{quit_tag: due} = :sys.get_state(wren)
        assert {:ok, _report} = Mind.percepts(wren)
        refute quits?(wren, due)
      end

      # Left alone, the quit that is due goes off with no call since.
      %{quit_tag: due} = :sys.get_state(wren)
      assert quits?(wren, due)
    end
  end

  # Makes the quit `tag` go off now, and says whether the Mind stopped for it.
  defp quits?(mind, tag) do
    send(mind, {:quit, tag})
    :sys.get_state(mind)
    false
  catch
    :exit, _stopped -> true
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
