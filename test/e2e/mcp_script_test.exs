defmodule Avwe.E2E.MCPScriptTest do
  @moduledoc """
  End to end over real HTTP with `scripts/mcp_call.py`, the stdlib client
  for manual play: Lantern Hollow at noon, on a manual clock. Each test
  keeps its saved session in its own tmp dir.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0, eventually: 1]

  alias Avwe.MCP.Players

  @world :hollow_script
  @ref :hollow_script_server
  @script Path.expand("../../scripts/mcp_call.py", __DIR__)

  if System.find_executable("python3") == nil do
    @moduletag skip: "python3 is not installed"
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)

    start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
    %{port: Avwe.MCP.port(@ref), session_file: Path.join(tmp_dir, "mcp_session")}
  end

  defp run(context, args) do
    env = [
      {"AVWE_MCP_URL", "http://127.0.0.1:#{context.port}/mcp"},
      {"AVWE_MCP_SESSION_FILE", context.session_file}
    ]

    {out, status} = System.cmd("python3", [@script | args], env: env, stderr_to_stdout: true)
    {status, out}
  end

  defp saved(context), do: context.session_file |> File.read!() |> Jason.decode!()

  test "plays a body across calls, and --leave lets go of it and ends the session", context do
    assert {0, out} = run(context, ["join", ~s({"body": "wren"})])
    assert out =~ "You are Wren, at Hollow Green."
    session = saved(context)["session"]
    assert {:session, ^session} = Players.playing(@world)["wren"]

    assert {0, out} = run(context, ["look"])
    assert out =~ "You are Wren"

    assert {0, out} = run(context, ["--leave"])
    assert out =~ "You let go of Wren; their routine carries them on."
    assert out =~ "Session ended."
    refute File.exists?(context.session_file)
    eventually(fn -> Players.playing(@world)["wren"] == nil end)
    assert {:ok, %{status: :terminated}} = ExMCP.SessionManager.get_session(session)
  end

  test "a session the server has forgotten (404) is started again, once", context do
    assert {0, _out} = run(context, ["bodies"])
    old = saved(context)["session"]
    :ok = ExMCP.SessionManager.terminate_session(old)

    assert {0, out} = run(context, ["bodies"])
    assert out =~ "(The saved session is gone; starting a new one.)"
    assert out =~ "Bodies in"
    assert saved(context)["session"] != old
  end

  test "any other refusal (400) is printed as the server gave it, and nothing starts over",
       context do
    File.write!(
      context.session_file,
      Jason.encode!(%{
        "url" => "http://127.0.0.1:#{context.port}/mcp",
        "session" => "not*a*session",
        "next_id" => 2
      })
    )

    assert {1, out} = run(context, ["bodies"])
    assert out =~ "The server refused the request: HTTP 400: Invalid session ID"
    refute out =~ "starting a new one"
    refute out =~ "Can't reach"
    assert saved(context)["session"] == "not*a*session"
  end

  test "a server that is not there is told as such", context do
    assert {1, out} = run(%{context | port: 1}, ["bodies"])
    assert out =~ "Can't reach the MCP server at http://127.0.0.1:1/mcp"
  end
end
