defmodule Avwe.E2E.AutopilotTest do
  @moduledoc """
  End to end through sessions and telnet: the Ember Reach with Mira on her
  own, watched; a player taking her over mid-journey and leaving again; a
  session that goes idle; and the canon check on the Hearth Compact, the
  evening before the river fails against the same evening a year later.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  alias Avwe.Session

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

    mira = join(port, "mira")
    expect(mira, "You are on your way to The Dry Bend.")
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()

    send_line(mira, "go lodge")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You give up on going to The Dry Bend.")
    expect(mira, "You set off toward Ashwarden Lodge.")
    Avwe.step(@world, 12)
    expect(mira, "You arrive at Ashwarden Lodge.")

    # Past 06:30 her survey does not start: she is being played.
    Avwe.step(@world, steps_until(7))
    refute_line(mira, "You set off")
    send_line(mira, "look")
    expect(mira, "You are Mira Vale, at Ashwarden Lodge.")

    send_line(mira, "quit")
    expect(mira, "Goodbye.")
    assert closed?(mira)
    eventually(fn -> not mira().taken end)
    Avwe.step(@world, 2)
    assert %{controller: :autopilot} = mira()

    # The 11:00 entry takes her home, and the watcher sees her go.
    Avwe.step(@world, steps_until(11, 10))
    expect(watcher, "Mira Vale leaves, heading toward Ember Reach.")
    expect(watcher, "Mira Vale arrives at Ember Reach.")
  end

  test "an idle session yields the body to autopilot until it acts again" do
    {:ok, _owner} = Avwe.subscribe(@world)
    {:ok, session} = Avwe.connect(@world, body: "mira-vale", idle_after: 500)
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()

    Process.sleep(600)
    Avwe.step(@world, 1)
    assert %{controller: :autopilot, taken: true} = mira()
    Avwe.step(@world, 1)
    assert [_decision | _rest] = decisions()

    # Her act retakes control first, and replaces what autopilot had her
    # doing: she sees that end, and her own intent's result, nothing else.
    {:ok, ref} = Session.act(session, :wait, params: %{for: 60})
    Avwe.step(@world, 1)
    assert %{controller: :human, taken: true} = mira()

    assert [
             %{intent: "auto-mira-vale-" <> _step, outcome: :interrupted, reason: :replaced},
             %{intent: ^ref, outcome: :success}
           ] = session |> percepts() |> Enum.filter(&(&1.kind == :result))

    Avwe.step(@world, 30)
    assert decisions() == []
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
