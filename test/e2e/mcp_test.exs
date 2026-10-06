defmodule Avwe.E2E.MCPTest do
  @moduledoc """
  End to end over real HTTP with ExMCP's client: the MCP tools in Lantern
  Hollow at noon, on a manual clock, beside telnet players. Wren and
  Tamsin stand together on Hollow Green.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0, eventually: 1]
  import Avwe.Test.MCPClient
  import Avwe.Test.TelnetClient, only: [join: 2, send_line: 2, sync: 1]

  alias Avwe.MCP.Players

  @world :hollow_mcp
  @ref :hollow_mcp_server

  setup do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)

    start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
    telnet = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    client = connect(Avwe.MCP.port(@ref))
    on_exit(fn -> stop_quietly(client) end)
    %{client: client, port: Avwe.MCP.port(@ref), telnet: telnet}
  end

  defp stop_quietly(client) do
    close(client)
  catch
    :exit, _gone -> :ok
  end

  test "a player on a long wait is interrupted when someone beside them speaks; the wait goes on",
       %{client: client, telnet: telnet} do
    refute call(client, "join", %{"body" => "wren"}).error?
    tamsin = join(telnet, "tamsin")

    task = calling(client, @world, "wren", "wait", %{"minutes" => 60})
    Avwe.step(@world, 2)
    send_line(tamsin, "say Wren, look at the pond.")
    sync(tamsin)
    result = step_until_done(task, @world, "wren", 3)

    assert result.data["status"] == "interrupted"
    assert result.text =~ ~r/^Interrupted: .* Under way: wait\./
    assert result.text =~ ~r/^\d\d:\d\d Tamsin says, "Wren, look at the pond\."$/m
    assert %{"verb" => "wait"} = result.data["action"]

    look = call(client, "look")
    assert look.text =~ "You are waiting here a while."
    assert %{"verb" => "wait"} = look.data["action"]

    Avwe.step(@world, 3)
    assert %{data: %{"status" => "still_going", "percepts" => []}} = call(client, "listen")
  end

  test "an act that outlasts max_wait_seconds is still going, and listen shows it finish",
       %{client: client} do
    refute call(client, "join", %{"body" => "wren"}).error?

    plan = %{
      "steps" => [
        %{"verb" => "wait", "params" => %{"minutes" => 5}},
        %{"verb" => "say", "params" => %{"text" => "Done waiting."}}
      ],
      "max_wait_seconds" => 0.2
    }

    going = call(client, "act", plan)
    assert going.data["status"] == "still_going"
    assert going.text =~ ~r/^Still going\. .* Under way: wait\. Planned after it: say\./
    assert [%{"verb" => "say", "params" => %{"text" => "Done waiting."}}] = going.data["plan"]

    step(@world, "wren", 7)

    listened = call(client, "listen")
    assert listened.data["status"] == "done"
    assert listened.text =~ ~r/^Done\./
    assert listened.text =~ ~r/^12:0\d You finish waiting\.$/m
    assert listened.text =~ ~r/^12:0\d You say, "Done waiting\."$/m
  end

  test "errors are tool errors in plain words, and a body comes and goes with its lease",
       %{client: client, telnet: telnet} do
    assert %{error?: true, text: "You are not playing anyone." <> _} =
             call(client, "act", %{"verb" => "say", "params" => %{"text" => "hi"}})

    _tamsin = join(telnet, "tamsin")
    taken = call(client, "join", %{"body" => "Tamsin"})
    assert taken.error? and taken.text =~ "being played by someone else"

    unknown = call(client, "join", %{"body" => "ghost"})
    assert unknown.error? and unknown.text =~ ~s(There is no body called "ghost")

    refute call(client, "join", %{"body" => "wren"}).error?
    again = call(client, "join", %{"body" => "pell"})
    assert again.error? and again.text =~ "You already play Wren. Call leave first."

    dance = call(client, "act", %{"verb" => "dance"})
    assert dance.error?
    assert dance.text =~ ~s(Unknown verb "dance". The verbs are: go, follow, walk, wait)

    bodies = call(client, "bodies")
    assert bodies.text =~ "- Wren (id: wren): you are playing them."
    assert bodies.text =~ "- Tamsin (id: tamsin): being played by someone else."

    Avwe.step(@world, 1)
    assert holder("wren") == :mcp

    left = call(client, "leave")
    assert left.text =~ "You let go of Wren; their routine carries them on."
    eventually(fn -> not taken?("wren") end)
    Avwe.step(@world, 1)
    assert holder("wren") == nil
    assert call(client, "bodies").text =~ "- Wren (id: wren): free; their routine has them."
    assert call(client, "leave").error?
  end

  test "a failed step is reported as failed, with the world's own words", %{client: client} do
    refute call(client, "join", %{"body" => "wren"}).error?

    task =
      calling(client, @world, "wren", "act", %{
        "steps" => [%{"verb" => "go", "target" => "atlantis"}, %{"verb" => "stop"}]
      })

    failed = step_until_done(task, @world, "wren", 3)
    assert failed.data["status"] == "failed"
    assert failed.text =~ ~r/^Failed: /
    assert failed.text =~ ~r/^12:01 You don't know the way there\.$/m
    assert failed.data["plan"] == []
  end

  test "the MCP session ending (DELETE) gives the body back", %{port: port} do
    other = connect(port)
    refute call(other, "join", %{"body" => "pell"}).error?
    assert taken?("pell")

    close(other)
    eventually(fn -> not taken?("pell") end)
    assert mind(@world, "pell") == nil
  end

  test "an MCP session that expires in ExMCP gives the body back at the next sweep", %{
    client: client
  } do
    refute call(client, "join", %{"body" => "pell"}).error?
    session = Players.playing(@world)["pell"]
    # Expiry, as ExMCP's session manager does it: no DELETE comes.
    :ok = ExMCP.SessionManager.terminate_session(session)
    assert taken?("pell")

    send(Players, :sweep)
    eventually(fn -> not taken?("pell") end)
  end

  test "a client without an MCP session (MCP 2026-07-28) plays with a player token", %{
    port: port
  } do
    modern = connect(port, :modern_only)

    joined = call(modern, "join", %{"body" => "odo"})
    refute joined.error?
    assert "player-" <> _ = token = joined.data["player"]
    assert joined.text =~ "Your player token is #{token}. Pass it as player to every other tool."

    assert call(modern, "look").error?
    assert call(modern, "look", %{"player" => token}).text =~ "You are Odo"

    task = calling(modern, @world, "odo", "say", %{"text" => "Anyone?", "player" => token})
    assert step_until_done(task, @world, "odo", 2).text =~ ~s(You say, "Anyone?")

    assert call(modern, "leave", %{"player" => token}).text =~ "You let go of Odo"
    eventually(fn -> not taken?("odo") end)
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
