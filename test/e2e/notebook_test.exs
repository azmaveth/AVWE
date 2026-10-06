defmodule Avwe.E2E.NotebookTest do
  @moduledoc """
  End to end over real TCP: Mira's survey notebook, and what she did while
  nobody held her. The Ember Reach from 04:00 on day 220 of 813 AR, with a
  manual clock.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.TelnetClient

  @world :ember_notebook

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts())
    on_exit(fn -> Avwe.stop_world(@world) end)

    telnet = start_supervised!({Avwe.Telnet, port: 0})
    %{port: Avwe.Telnet.port(telnet)}
  end

  defp mira_free do
    eventually(fn ->
      {:ok, bodies} = Avwe.bodies(@world)
      not hd(bodies).taken
    end)
  end

  test "a player writes in the notebook, reads it back, and the next player finds it", %{
    port: port
  } do
    mira = join(port, "mira")
    expect(mira, "You carry your survey notebook (empty).")

    send_line(mira, "write")
    expect(mira, "Write what?")

    send_line(mira, "write The reeds at the bend lean north.")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You write in your survey notebook.")

    send_line(mira, "read")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You read your survey notebook (1 of 1 page):")
    expect(mira, "  813 AR, day 220, 04:01: The reeds at the bend lean north.")

    send_line(mira, "look")
    expect(mira, "You carry your survey notebook (1 page).")

    send_line(mira, "quit")
    assert closed?(mira)
    mira_free()

    next = join(port, "mira")
    send_line(next, "notes")
    sync(next)
    Avwe.step(@world, 1)
    expect(next, "You read your survey notebook (1 of 1 page):")
    expect(next, "  813 AR, day 220, 04:01: The reeds at the bend lean north.")

    send_line(next, "write #{String.duplicate("x", 1_001)}")
    sync(next)
    Avwe.step(@world, 1)
    expect(next, "You can't write that. A page holds 1 to 1000 characters.")
  end

  test "read takes how many pages, and help tells the notebook commands", %{port: port} do
    mira = join(port, "mira")

    send_line(mira, "help")
    expect(mira, "  write <text>      write a page in your notebook")
    expect(mira, "  read [pages]      read the last pages of your notebook (also: notes)")

    for page <- ["First.", "Second.", "Third."] do
      send_line(mira, "write #{page}")
      sync(mira)
      Avwe.step(@world, 1)
      expect(mira, "You write in your survey notebook.")
    end

    send_line(mira, "read 2")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You read your survey notebook (2 of 3 pages):")
    lines = expect(mira, ~r/^  813 AR, day 220, 04:03: Third\.$/)
    assert Enum.any?(lines, &(&1 == "  813 AR, day 220, 04:02: Second."))
    refute Enum.any?(lines, &(&1 =~ "First."))

    send_line(mira, "read two")
    expect(mira, "Read how many pages? Try: read, read 5.")
  end

  test "a page reaches the reader as plain text: no escape codes, no tabs", %{port: port} do
    mira = join(port, "mira")
    send_line(mira, "write The bend.\tDry.\e[2J\e[31m Red?\a")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You write in your survey notebook.")

    send_line(mira, "read")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, "You read your survey notebook (1 of 1 page):")
    [page] = expect(mira, ~r/^  813 AR, day 220, 04:01: /) |> Enum.take(-1)
    assert page == "  813 AR, day 220, 04:01: The bend. Dry. Red?"
  end

  test "joining tells what the body did while nobody held it", %{port: port} do
    # Her routine walks her to the Dry Bend at 04:30.
    Avwe.step(@world, 90)

    mira = connect(port)
    expect(mira, "watch without a body")
    send_line(mira, "mira")
    expect(mira, "813 AR, day 220, 05:30. It is dark.")
    expect(mira, "While you were away:")
    away = expect(mira, ~r/^You are Mira Vale/)
    assert Enum.any?(away, &(&1 =~ ~r/^  04:\d\d You arrive at The Dry Bend\.$/))

    # Held, she is not away: a look says nothing of it.
    sync(mira)
    Avwe.step(@world, 1)
    send_line(mira, "look")
    refute_line(mira, "While you were away:")

    send_line(mira, "say Is anyone out here?")
    sync(mira)
    Avwe.step(@world, 1)
    expect(mira, ~s(You say, "Is anyone out here?"))
    send_line(mira, "quit")
    assert closed?(mira)
    mira_free()

    # The next player is told only what happened since she was let go.
    Avwe.step(@world, 60)
    again = join(port, "mira", "While you were away:")
    away = expect(again, ~r/^You are Mira Vale/)
    assert hd(away) =~ ~r/^  05:3\d You let your routine carry you\.$/
    refute Enum.any?(away, &(&1 =~ "You arrive at The Dry Bend" and &1 =~ ~r/^  04:/))
    refute Enum.any?(away, &(&1 =~ "Is anyone out here?"))
  end
end
