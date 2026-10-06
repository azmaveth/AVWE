defmodule Avwe.E2E.AutopilotTest do
  @moduledoc """
  End to end through sessions and telnet: the Ember Reach with Mira on her
  own, watched; a player taking her over mid-journey and leaving again; a
  session and a telnet player that go idle and see the hand-over (and not
  the routine's waits, except one they stop, or one they take back and
  let run out; nor the step home that finds her home); the `- ` mark and
  the look's wording, which follow who holds the body; a session kept in
  hand by looking, touching or asking the time; and the canon check on the
  Hearth Compact, the evening before the river fails against the same
  evening a year later.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  alias Avwe.{Percept, Prose, Session}

  @world :ember_autopilot
  @moduletag start: {813, day: 220, hour: 4}

  setup %{start: start} do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: start))
    on_exit(fn -> Avwe.stop_world(@world) end)
    :ok
  end

  defp mira do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == "mira-vale"))
  end

  defp mira_action do
    {:ok, snapshot} = Avwe.snapshot(@world)
    get_in(snapshot.components, [:action, "mira-vale"])
  end

  # Steps the world a minute at a time until Mira is walking somewhere.
  defp step_until_walking(limit \\ 60) do
    eventually(
      fn ->
        Avwe.step(@world, 1)
        match?(%{verb: :go}, mira_action())
      end,
      limit * 100
    )
  end

  defp steps_until(hour, minute \\ 0) do
    {:ok, %{time: time}} = Avwe.snapshot(@world)
    %{hour: h, minute: m} = Avwe.Calendar.describe(time)
    (hour - h) * 60 + (minute - m)
  end

  test "a watcher sees Mira set out for the bend and come home by evening" do
    {:ok, watcher} = Avwe.connect(@world)
    Avwe.step(@world, 60)

    seen = summaries(watcher)
    assert "Mira Vale leaves, heading toward The Dry Bend." in seen
    assert "Mira Vale arrives at The Dry Bend." in seen
    assert %{controller: :autopilot, taken: false} = mira()

    Avwe.step(@world, steps_until(23))
    assert {:ok, %{bodies: [%{name: "Mira Vale", at: "Ember Reach"}]}} = Session.look(watcher)
  end

  test "a telnet player takes Mira over mid-journey and gives her back" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    watcher = join(port, "watch", "You are watching.")
    step_until_walking()

    # The take is in the world's hands until it steps: the look on joining
    # still reads the journey as the routine's, the next as her own.
    mira = join(port, "mira")
    expect(mira, "Your routine has you on your way to The Dry Bend.")
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()
    send_line(mira, "look")
    expect(mira, "You are on your way to The Dry Bend.")

    send_line(mira, "go lodge")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You give up on going to The Dry Bend.")
    expect(mira, "You set off toward Ashwarden Lodge.")
    Avwe.step(@world, 12)
    expect(mira, "You arrive at Ashwarden Lodge.")

    # Past 08:00 her survey does not start: she is being played.
    Avwe.step(@world, steps_until(8, 30))
    refute_line(mira, "You set off")
    send_line(mira, "look")
    expect(mira, "You are Mira Vale, at Ashwarden Lodge.")

    send_line(mira, "quit")
    expect(mira, "Goodbye.")
    assert closed?(mira)
    eventually(fn -> not mira().taken end)
    Avwe.step(@world, 2)
    assert %{controller: :autopilot} = mira()

    # The survey she missed starts now that she is her own again, and the
    # watcher sees her go and, three hours at the bend later, come home.
    expect(watcher, "Mira Vale leaves, heading toward The Dry Bend.")
    Avwe.step(@world, steps_until(12, 30))
    expect(watcher, "Mira Vale arrives at The Dry Bend.")
    expect(watcher, "Mira Vale leaves, heading toward Ember Reach.")
    expect(watcher, "Mira Vale arrives at Ember Reach.")
  end

  test "an idle session yields the body to autopilot until it acts again" do
    {:ok, _owner} = Avwe.subscribe(@world)
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 500)
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()
    refute Enum.any?(percepts(session), &(&1.type in [:control_taken, :control_released]))

    Process.sleep(600)
    Avwe.step(@world, 1)
    assert %{controller: :autopilot, taken: true} = mira()
    Avwe.step(@world, 1)
    assert [_decision | _rest] = decisions()

    # She senses the hand-over, and nothing of the rest her routine settles
    # her into: autopilot's waits are quiet.
    assert %{verb: :wait, ref: "auto-mira-vale-" <> _step} = mira_action()

    assert [
             %Percept{
               kind: :sensed,
               type: :control_released,
               salience: 0.3,
               summary: "You let your routine carry you."
             }
           ] = percepts(session)

    # Her act retakes control first, and replaces what autopilot had her
    # doing: she sees her own intent's result, and nothing of the quiet wait
    # it ended.
    {:ok, ref} = Session.act(session, :wait, params: %{for: 60})
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()

    assert [
             %Percept{
               kind: :sensed,
               type: :control_taken,
               salience: 0.3,
               summary: "You take yourself in hand."
             },
             %Percept{kind: :progress, intent: ^ref, issuer: :controller},
             %Percept{kind: :result, intent: ^ref, issuer: :controller, outcome: :success}
           ] = percepts(session)

    Avwe.step(@world, 30)
    assert decisions() == []
  end

  test "a session yielded for a whole day hears the routine's journeys, never its waits" do
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 100)
    Process.sleep(200)
    Avwe.step(@world, 1440)
    assert %{controller: :autopilot} = mira()

    [first | rest] = percepts(session)
    assert %Percept{type: :control_released} = first
    own = Enum.filter(rest, &(&1.kind in [:progress, :result]))
    assert own != []
    assert Enum.all?(own, &(&1.issuer == :autopilot))
    assert "You set off toward The Dry Bend." in Enum.map(own, & &1.summary)
    assert "You arrive at Ashwarden Lodge." in Enum.map(own, & &1.summary)
    refute Enum.any?(own, &(&1.summary =~ ~r/wait/))
  end

  test "a session that keeps looking is not yielded" do
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 300)

    for _n <- 1..5 do
      Process.sleep(100)
      assert {:ok, %{spectator: false}} = Session.look(session)
    end

    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()
    refute Enum.any?(percepts(session), &(&1.type == :control_released))

    Process.sleep(400)
    Avwe.step(@world, 1)
    assert %{controller: :autopilot, taken: true} = mira()
  end

  test "a telnet player who stops typing sees the routine take over, marked" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
    watcher = join(port, "watch", "You are watching.")
    mira = join(port, "mira")
    Avwe.step(@world, 1)
    assert %{controller: :human} = mira()

    Process.sleep(400)
    Avwe.step(@world, 1)
    expect(mira, "You let your routine carry you.")
    assert %{controller: :autopilot} = mira()

    # The routine's lines for her carry the mark; the watcher's do not. The
    # wait at the bend says nothing.
    step_until_walking()
    expect(mira, "- You set off toward The Dry Bend.")
    send_line(mira, "look")
    expect(mira, "Your routine has you on your way to The Dry Bend.")
    Avwe.step(@world, 12)
    expect(mira, "- You arrive at The Dry Bend.")
    expect(watcher, "Mira Vale arrives at The Dry Bend.")
    Avwe.step(@world, 3)
    assert %{verb: :wait, ref: "auto-" <> _step} = mira_action()
    refute_line(mira, ~r/wait/)
    refute_line(watcher, ~r/routine|in hand|^- /)

    send_line(mira, "look")
    expect(mira, "Your routine has you waiting here.")
    assert %{controller: :autopilot} = mira()

    send_line(mira, "help")

    expect(
      mira,
      ~s(Lines starting with "- " are what your routine does with you while you stop acting; any command you type keeps you in hand a while longer, and any command that acts \(go, say, wait, light...\) takes you back if the routine had you.)
    )

    assert %{controller: :autopilot} = mira()
    send_line(mira, "wait 1")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You take yourself in hand.")
    expect(mira, "You settle in to wait.")
    assert %{controller: :human} = mira()
    Avwe.step(@world, 1)
    expect(mira, "You finish waiting.")
    refute_line(watcher, ~r/routine|in hand|^- /)
  end

  test "a telnet player who takes over mid-journey reads its remaining lines, and their stop, unmarked" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    step_until_walking()

    mira = join(port, "mira")
    expect(mira, "Your routine has you on your way to The Dry Bend.")
    Avwe.step(@world, 5)
    walked = expect(mira, ~r/^You're (a quarter of the way|halfway|nearly at)/)
    send_line(mira, "look")
    expect(mira, "You are on your way to The Dry Bend.")

    send_line(mira, "stop")
    sync(mira)
    Avwe.step(@world, 1)
    stopped = expect(mira, "You stop short of The Dry Bend.")
    refute Enum.any?(walked ++ stopped, &String.starts_with?(&1, "- "))

    send_line(mira, "look")
    expect(mira, ~r/^You are Mira Vale, \d+ m [a-z-]+ of /)
  end

  test "stopping the wait the routine has her in says so" do
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 100)
    Process.sleep(200)
    Avwe.step(@world, 2)
    assert %{verb: :wait, ref: "auto-" <> _step = ref} = mira_action()
    assert [%Percept{type: :control_released}] = percepts(session)

    # Resting until dawn at 04:00, her look says whose wait it is.
    {:ok, look} = Session.look(session)
    assert Prose.look(look) =~ "Your routine has you resting until dawn."

    {:ok, stop} = Session.act(session, :stop)
    Avwe.step(@world, 1)

    assert [
             %Percept{type: :control_taken},
             %Percept{
               kind: :result,
               intent: ^ref,
               issuer: :autopilot,
               outcome: :interrupted,
               reason: :stopped,
               summary: "You stop waiting."
             },
             %Percept{kind: :result, intent: ^stop, outcome: :success, summary: nil}
           ] = percepts(session)

    assert mira_action() == nil
  end

  test "a session that only peeks is yielded, and a peek neither tells nor takes the time away" do
    Avwe.step(@world, 120)
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 300)

    # Nobody held her while she walked the banks, but a peek does not say so.
    assert {:ok, %{spectator: false, away: []}} = Session.peek(session)

    for _n <- 1..5 do
      Process.sleep(100)
      assert {:ok, %{spectator: false, away: []}} = Session.peek(session)
    end

    Avwe.step(@world, 1)
    assert %{controller: :autopilot, taken: true} = mira()
    assert Enum.any?(percepts(session), &(&1.type == :control_released))
  end

  test "a peek does not spend the first look's account of the time away" do
    Avwe.step(@world, 120)
    {:ok, session} = Avwe.connect(@world, body: "mira-vale")
    assert {:ok, _look} = Session.peek(session)

    # In hand now, so the world's own account is empty: what the first look
    # tells is what the session found when it connected.
    Avwe.step(@world, 1)
    assert {:ok, %{away: [_ | _]}} = Session.look(session)
    assert {:ok, %{away: []}} = Session.look(session)
  end

  test "a peek at a world as a spectator is a look with nobody in it" do
    {:ok, watcher} = Avwe.connect(@world)
    assert {:ok, %{spectator: true}} = Session.peek(watcher)
  end

  test "a session that keeps touching is not yielded" do
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 300)

    for _n <- 1..5 do
      Process.sleep(100)
      assert :ok = Session.touch(session)
    end

    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()
    refute Enum.any?(percepts(session), &(&1.type == :control_released))

    Process.sleep(400)
    Avwe.step(@world, 1)
    assert %{controller: :autopilot, taken: true} = mira()
    assert [%Percept{type: :control_released}] = percepts(session)
  end

  test "a telnet player who keeps reading help is not yielded either" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
    mira = join(port, "mira")

    for _n <- 1..5 do
      Process.sleep(100)
      send_line(mira, "help")
      expect(mira, "takes you back if the routine had you.")
    end

    Avwe.step(@world, 1)
    assert %{controller: :human} = mira()
    refute_line(mira, "You let your routine carry you.")
  end

  test "a telnet player who keeps asking the time is not yielded" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
    mira = join(port, "mira")

    for _n <- 1..5 do
      Process.sleep(100)
      send_line(mira, "time")
      expect(mira, ~r/^813 AR, day 220, \d\d:\d\d$/)
    end

    Avwe.step(@world, 1)
    assert %{controller: :human} = mira()
    refute_line(mira, "You let your routine carry you.")

    Process.sleep(400)
    Avwe.step(@world, 1)
    expect(mira, "You let your routine carry you.")
    assert %{controller: :autopilot} = mira()
  end

  @tag start: {813, day: 220, hour: 21}
  test "a yielded player hears nothing of the night's step home when she is home already" do
    {:ok, _owner} = Avwe.subscribe(@world)
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
    mira = join(port, "mira")
    Avwe.step(@world, 1)
    Process.sleep(400)
    Avwe.step(@world, 1)
    expect(mira, "You let your routine carry you.")

    # Resting at home across 22:00, when the rest entry's `go` home finds
    # her there: neither it nor the rest it leads to says a word.
    Avwe.step(@world, steps_until(22, 15))
    assert %{verb: :wait, params: %{until: :dawn}, ref: "auto-" <> _step} = mira_action()
    assert [_home, _rest] = Enum.filter(decisions(), &(&1.data.why == :routine))
    refute_line(mira, ~r/already at|set off|wait/)
    send_line(mira, "look")
    expect(mira, "Your routine has you resting until dawn.")
  end

  @tag start: {813, day: 220, hour: 13}
  test "a wait the routine began is the player's once they have the body back: their look says so, and so does its end" do
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 300)
    Process.sleep(400)
    Avwe.step(@world, 2)
    assert %{verb: :wait, params: %{for: 3600}, ref: "auto-" <> _step = ref} = mira_action()
    assert [%Percept{type: :control_released}] = percepts(session)
    assert {:ok, %{holder: nil} = look} = Session.look(session)
    assert Prose.look(look) =~ "Your routine has you waiting here."

    # Speaking takes her back and leaves the wait running: it is hers now.
    {:ok, said} = Session.act(session, :say, params: %{text: "Still here."})
    Avwe.step(@world, 1)

    assert [
             %Percept{type: :control_taken},
             %Percept{kind: :result, intent: ^said, outcome: :success}
           ] = percepts(session)

    assert %{verb: :wait, ref: ^ref} = mira_action()
    assert {:ok, %{holder: :human} = look} = Session.look(session)
    assert Prose.look(look) =~ "You are waiting here a while."
    refute Prose.look(look) =~ "routine"

    # Present while the hour passes, she keeps the body: the wait ends as
    # hers, and the routine issues nothing after it.
    for _n <- 1..3 do
      Avwe.step(@world, 20)
      :ok = Session.touch(session)
    end

    assert mira_action() == nil
    assert %{controller: :human} = mira()

    assert [
             %Percept{
               kind: :result,
               intent: ^ref,
               issuer: :autopilot,
               outcome: :success,
               summary: "You finish waiting."
             }
           ] = session |> percepts() |> Enum.filter(&(&1.kind == :result))
  end

  @tag start: {813, day: 220, hour: 13}
  test "a telnet player who speaks has the routine's wait as their own: their look says so, and its end is said, unmarked" do
    port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
    mira = join(port, "mira")
    Avwe.step(@world, 1)
    Process.sleep(400)
    Avwe.step(@world, 2)
    expect(mira, "You let your routine carry you.")
    assert %{verb: :wait, ref: "auto-" <> _step} = mira_action()
    send_line(mira, "look")
    expect(mira, "Your routine has you waiting here.")

    send_line(mira, "say Still here.")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You take yourself in hand.")
    expect(mira, ~s(You say, "Still here."))
    assert %{controller: :human} = mira()
    assert %{verb: :wait, ref: "auto-" <> _step} = mira_action()
    send_line(mira, "look")
    expect(mira, "You are waiting here a while.")

    # Asking the time now and then keeps the body through the hour.
    for _n <- 1..2 do
      Avwe.step(@world, 20)
      sync(mira)
    end

    Avwe.step(@world, 20)
    lines = expect(mira, "You finish waiting.")
    refute Enum.any?(lines, &String.starts_with?(&1, "- "))
    assert mira_action() == nil
    assert %{controller: :human} = mira()
  end

  # The `:decided` events for Mira since the last call, from the world's
  # event stream (bodies never perceive them).
  defp decisions do
    receive do
      {:avwe_events, @world, events, _view} ->
        for(%{type: :decided, entity: "mira-vale"} = event <- events, do: event) ++ decisions()
    after
      0 -> []
    end
  end

  describe "the Hearth Compact" do
    @describetag start: {812, day: 199, hour: 18}

    @tag start: {812, day: 199, hour: 3}
    test "a yielded player sees the fire the routine lights, marked, and takes the body back by stopping" do
      port = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0, idle_after: 300}))
      mira = join(port, "mira")
      Avwe.step(@world, 1)
      assert %{controller: :human} = mira()

      Process.sleep(400)
      Avwe.step(@world, 1)
      expect(mira, "You let your routine carry you.")

      Avwe.step(@world, 10)
      expect(mira, "- You light the kiln-house hearth.")
      Avwe.step(@world, 2)
      assert %{verb: :wait, ref: "auto-" <> _step} = mira_action()
      send_line(mira, "look")
      expect(mira, "The kiln-house hearth is burning here.")
      expect(mira, "Your routine has you waiting here.")

      # Stopping the quiet wait says so, and the line is hers, unmarked.
      send_line(mira, "stop")
      sync(mira)
      Avwe.step(@world, 1)
      expect(mira, "You take yourself in hand.")
      lines = expect(mira, "You stop waiting.")
      refute Enum.any?(lines, &String.starts_with?(&1, "- "))
      assert %{controller: :human} = mira()
    end

    test "the evening before the river fails, a watcher sees Mira light the kiln-house hearth" do
      {:ok, watcher} = Avwe.connect(@world)
      Avwe.step(@world, 5 * 60)

      assert "Mira Vale lights the kiln-house hearth." in summaries(watcher)
      assert {:ok, %{fires: fires}} = Session.look(watcher)
      assert %{id: "town-hearth", burning: true} = Enum.find(fires, &(&1.id == "town-hearth"))
    end

    @tag start: {813, day: 220, hour: 18}
    test "a year later, the same evening, the chimney stays cold" do
      {:ok, watcher} = Avwe.connect(@world)
      Avwe.step(@world, 12 * 60)

      assert {:ok, %{bodies: [%{at: "Ember Reach"}], fires: fires}} = Session.look(watcher)
      assert %{id: "town-hearth", burning: false} = Enum.find(fires, &(&1.id == "town-hearth"))

      # And through the rest of the cold, up to 07:00.
      Avwe.step(@world, 60)
      refute "Mira Vale lights the kiln-house hearth." in summaries(watcher)
      assert {:ok, %{fires: fires}} = Session.look(watcher)

      assert %{id: "town-hearth", burning: false, fuel_kg: 8.0} =
               Enum.find(fires, &(&1.id == "town-hearth"))
    end
  end
end
