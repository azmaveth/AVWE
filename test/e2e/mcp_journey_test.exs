defmodule Avwe.E2E.MCPJourneyTest do
  @moduledoc """
  End to end over real HTTP with ExMCP's client: Claude plays Mira across
  two MCP sessions and finds the notes from the first (the M1 done
  criterion), and a note survives the world stopping and starting again.
  The Ember Reach, from 813 AR, day 220, 08:30, on a manual clock.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [ember_reach_opts: 1, eventually: 1]
  import Avwe.Test.MCPClient

  @world :ember_mcp
  @ref :ember_mcp_server
  @note "The reeds at the bend lean north."

  setup context do
    data_dir = context[:tmp_dir]
    :ok = start(data_dir)
    on_exit(fn -> Avwe.stop_world(@world) end)

    start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
    %{port: Avwe.MCP.port(@ref), data_dir: data_dir}
  end

  defp start(data_dir) do
    opts = ember_reach_opts(start: {813, day: 220, hour: 8, minute: 30}, data_dir: data_dir)
    {:ok, _pid} = Avwe.start_world(@world, opts)
    :ok
  end

  defp acted(client, tool, args) do
    client |> calling(@world, "mira-vale", tool, args) |> step_until_done(@world, "mira-vale")
  end

  test "Claude plays Mira across two sessions and finds the notes from the first", %{port: port} do
    first = connect(port)

    joined = call(first, "join", %{"body" => "Mira"})
    refute joined.error?
    assert joined.text =~ "You are Mira Vale."
    assert joined.data["body"] == "mira-vale"

    look = call(first, "look")
    assert look.text =~ "813 AR, day 220, 08:30"
    assert look.text =~ "You know the way to:"
    assert %{"places" => places, "affordances" => _, "body" => %{"id" => "mira-vale"}} = look.data
    assert Enum.any?(places, &(&1["name"] == "The Dry Bend" and is_integer(&1["distance_m"])))

    plan = %{
      "steps" => [
        %{"verb" => "go", "target" => "the dry bend"},
        %{"verb" => "wait", "params" => %{"minutes" => 20}}
      ]
    }

    walked = acted(first, "act", plan)
    refute walked.error?
    assert walked.data["status"] == "done"
    assert walked.text =~ ~r/^Done\. It is 813 AR, day 220, /
    assert walked.text =~ ~r/^\d\d:\d\d You set off toward The Dry Bend\.$/m
    assert walked.text =~ ~r/^\d\d:\d\d You arrive at The Dry Bend\.$/m
    assert walked.text =~ ~r/^\d\d:\d\d You finish waiting\.$/m

    wrote = acted(first, "write", %{"text" => @note})
    assert wrote.data["status"] == "done"
    assert wrote.text =~ "You write in your survey notebook."

    [_all, written_at] =
      Regex.run(~r/^(\d\d:\d\d) You write in your survey notebook\.$/m, wrote.text)

    left = call(first, "leave")
    refute left.error?
    assert left.text =~ "You let go of Mira Vale"
    close(first)

    # Four hours with nobody holding her: her routine has her.
    Avwe.step(@world, 1)
    assert holder() == nil
    Avwe.step(@world, 240)

    second = connect(port)
    rejoined = call(second, "join", %{"body" => "mira-vale"})
    refute rejoined.error?
    [_before, away] = String.split(rejoined.text, "While you were away:\n", parts: 2)
    away_lines = away |> String.split("\n") |> Enum.take_while(&String.starts_with?(&1, "  "))
    assert away_lines != []
    assert Enum.all?(away_lines, &(&1 =~ ~r/^  \d\d:\d\d [A-Z]/))
    # Her routine took her home from the bend.
    assert Enum.any?(away_lines, &(&1 =~ ~r/^  \d\d:\d\d You arrive at Ember Reach\.$/))
    assert rejoined.data["away"] != []

    read = acted(second, "read", %{})
    assert read.data["status"] == "done"
    assert read.text =~ "You read your survey notebook (1 of 1 page):"
    # The page carries the world time it was written: the start of the step
    # whose end the write's percept reports.
    [_all, page_at] = Regex.run(~r/^  813 AR, day 220, (\d\d:\d\d): /m, read.text)
    assert page_at <= written_at
    assert read.text =~ "#{page_at}: #{@note}"

    close(second)
  end

  @tag :tmp_dir
  test "a note written over MCP survives the world stopping and starting again", %{
    port: port,
    data_dir: data_dir
  } do
    first = connect(port)
    refute call(first, "join", %{"body" => "mira-vale"}).error?
    assert acted(first, "write", %{"text" => @note}).data["status"] == "done"
    mind = mind(@world, "mira-vale")
    monitor = Process.monitor(mind)

    # The first session never leaves: its Mind ends with the world.
    :ok = Avwe.stop_world(@world)
    assert_receive {:DOWN, ^monitor, :process, ^mind, :normal}, 1_000
    :ok = start(data_dir)

    assert call(first, "look").text =~ "You are not playing anyone."

    second = connect(port)
    refute call(second, "join", %{"body" => "mira-vale"}).error?
    read = acted(second, "read", %{"last" => 5})
    assert read.text =~ "You read your survey notebook (1 of 1 page):"
    assert read.text =~ @note

    close(second)
    close(first)
    eventually(fn -> mind(@world, "mira-vale") == nil end)
  end

  defp holder do
    {:ok, snapshot} = Avwe.snapshot(@world)
    snapshot.components.control["mira-vale"].holder
  end
end
