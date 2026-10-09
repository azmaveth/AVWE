defmodule Avwe.E2E.MCPGuestsTest do
  @moduledoc """
  End to end over real HTTP with ArborMCP's client: a player arrives in Lantern
  Hollow as a guest of its own making (the `arrive` tool), beside a telnet
  player. The world is at noon on a manual clock and takes two guests, who
  arrive on Hollow Green, where Wren and Tamsin stand.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0, eventually: 1]
  import Avwe.Test.MCPClient
  import Avwe.Test.TelnetClient, only: [expect: 2, join: 2, refute_line: 2]

  alias Arbor.MCP.Client

  @world :hollow_mcp_guests
  @ref :hollow_mcp_guests_server
  @tomas %{"name" => "Tomas Reed", "backstory" => "A salvage diver from Willow Docks."}

  setup context do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        guests: [arrival: "hollow-green", max: 2]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)

    start_supervised!(
      {Avwe.MCP, port: 0, world: @world, ref: @ref, arrival_wait: context[:arrival_wait]}
    )

    telnet = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    %{port: Avwe.MCP.port(@ref), telnet: telnet}
  end

  defp client(port, mode \\ :legacy_only) do
    client = connect(port, mode)
    on_exit(fn -> stop_quietly(client) end)
    client
  end

  defp stop_quietly(client) do
    close(client)
  catch
    :exit, _gone -> :ok
  end

  # An arrival is made at the world's next step, so the call waits for it:
  # started in a task, with the world stepped once its player is there.
  defp arrive(client, args, id) do
    task = Task.async(fn -> call(client, "arrive", args) end)
    assert eventually(fn -> mind(@world, id) != nil end)
    Avwe.step(@world, 1)
    Task.await(task)
  end

  describe "the arrive tool" do
    test "is offered, with the name required", %{port: port} do
      {:ok, %{tools: tools}} = Client.list_tools(client(port))
      arrive = Enum.find(tools, &((&1["name"] || &1[:name]) == "arrive"))
      schema = arrive["inputSchema"] || arrive[:inputSchema]

      assert schema["required"] == ["name"]
      assert %{"name" => _, "backstory" => _, "player" => _} = schema["properties"]
    end

    test "gives a body at the arrival place, and the first look", %{port: port} do
      tomas = client(port)
      arrived = arrive(tomas, @tomas, "guest-tomas-reed")

      refute arrived.error?
      assert arrived.text =~ "You arrive as a guest: Tomas Reed."
      assert arrived.text =~ "A salvage diver from Willow Docks."
      assert arrived.text =~ "You are Tomas Reed, at Hollow Green."

      assert %{
               "body" => "guest-tomas-reed",
               "guest" => %{
                 "name" => "Tomas Reed",
                 "backstory" => "A salvage diver from Willow Docks."
               },
               "look" => %{"body" => %{"id" => "guest-tomas-reed", "name" => "Tomas Reed"}},
               "away" => []
             } = arrived.data

      assert call(tomas, "look").text =~ "You are Tomas Reed, at Hollow Green."
    end

    test "plays like any body: a plan runs, and the notebook remembers", %{port: port} do
      tomas = client(port)
      arrive(tomas, @tomas, "guest-tomas-reed")
      body = "guest-tomas-reed"

      write = calling(tomas, @world, body, "write", %{"text" => "The well is deep."})
      assert %{error?: false, text: "Done." <> _} = step_until_done(write, @world, body, 10)

      go = calling(tomas, @world, body, "act", %{"verb" => "go", "target" => "mill-pond"})
      assert %{error?: false, text: "Done." <> _} = step_until_done(go, @world, body, 40)

      read = calling(tomas, @world, body, "read", %{})
      assert %{error?: false, text: text} = step_until_done(read, @world, body, 10)
      assert text =~ "The well is deep."
    end

    test "is seen by those in sight, over telnet, as they see anyone arrive", %{
      port: port,
      telnet: telnet
    } do
      wren = join(telnet, "wren")
      arrive(client(port), @tomas, "guest-tomas-reed")

      expect(wren, "Tomas Reed arrives at Hollow Green.")
    end

    test "is listed as a guest, and a guest is held until it leaves and taken back by name", %{
      port: port
    } do
      tomas = client(port)
      arrive(tomas, @tomas, "guest-tomas-reed")

      listed = call(client(port), "bodies")

      assert listed.text =~
               "Tomas Reed (id: guest-tomas-reed): being played by someone else. A guest."

      assert %{"guest" => true, "taken" => true} =
               Enum.find(listed.data["bodies"], &(&1["id"] == "guest-tomas-reed"))

      assert %{"guest" => false} = Enum.find(listed.data["bodies"], &(&1["id"] == "wren"))

      assert call(tomas, "leave").text =~ "You let go of Tomas Reed"
      Avwe.step(@world, 1)
      assert eventually(fn -> not Enum.find(bodies(), &(&1.id == "guest-tomas-reed")).taken end)

      # Taken back, it is told who it is, as it made itself up.
      again = call(client(port), "join", %{"body" => "Tomas Reed"})
      refute again.error?
      assert again.text =~ "You are a guest here: Tomas Reed."
      assert again.text =~ "A salvage diver from Willow Docks."
      assert %{"guest" => %{"backstory" => "A salvage diver from Willow Docks."}} = again.data
    end

    test "can be had with no backstory", %{port: port} do
      arrived = arrive(client(port), %{"name" => "Ines Cole"}, "guest-ines-cole")

      refute arrived.error?
      assert arrived.text =~ "You arrive as a guest: Ines Cole."
      refute arrived.text =~ "backstory"
      assert %{"guest" => %{"name" => "Ines Cole", "backstory" => nil}} = arrived.data
    end

    @tag arrival_wait: 100
    test "says it is still arriving when the world has not stepped, and look finds the guest", %{
      port: port
    } do
      tomas = client(port)
      promised = call(tomas, "arrive", @tomas)

      refute promised.error?
      assert promised.text =~ "on your way"
      assert %{"arriving" => true, "body" => "guest-tomas-reed"} = promised.data

      Avwe.step(@world, 1)
      assert call(tomas, "look").text =~ "You are Tomas Reed, at Hollow Green."
    end

    test "gives a client without an MCP session a token, as join does", %{port: port} do
      modern = client(port, :modern_only)
      arrived = arrive(modern, @tomas, "guest-tomas-reed")

      assert "player-" <> _ = token = arrived.data["player"]
      assert arrived.text =~ "Your player token is #{token}."
      assert call(modern, "look", %{"player" => token}).text =~ "You are Tomas Reed"
      assert call(modern, "leave", %{"player" => token}).text =~ "You let go of Tomas Reed"
    end
  end

  describe "the arrive tool refuses" do
    test "a name that is not a name", %{port: port} do
      tomas = client(port)

      for name <- ["x", "Tomas <b>", "someone", "12"] do
        refused = call(tomas, "arrive", %{"name" => name})
        assert refused.error?, name
        assert refused.text =~ "not a name a guest can have", name
      end

      assert call(tomas, "arrive", %{
               "name" => "Tomas Reed",
               "backstory" => String.duplicate("b", 1_001)
             }).text =~
               "up to 1000 characters"
    end

    test "a name that belongs to someone or something here, or to a guest", %{port: port} do
      first = client(port)

      for name <- ["Wren", "Hollow Green", "tamsin"] do
        assert %{error?: true, text: text} = call(first, "arrive", %{"name" => name})
        assert text =~ "taken", name
      end

      arrive(first, @tomas, "guest-tomas-reed")

      assert %{error?: true, text: text} =
               call(client(port), "arrive", %{"name" => "tomas  reed"})

      assert text =~ "That name is taken"
    end

    test "an arrival past the most the world takes, and one by somebody who plays already", %{
      port: port
    } do
      arrive(client(port), @tomas, "guest-tomas-reed")
      arrive(client(port), %{"name" => "Ines Cole"}, "guest-ines-cole")

      assert %{error?: true, text: text} = call(client(port), "arrive", %{"name" => "Pim Aldous"})
      assert text =~ "no room for more guests"

      tomas = client(port)
      refute call(tomas, "join", %{"body" => "odo"}).error?
      assert %{error?: true, text: text} = call(tomas, "arrive", %{"name" => "Pim Aldous"})
      assert text =~ "You already play Odo"
    end

    test "a world that takes no guests" do
      {:ok, _pid} =
        Avwe.start_world(:hollow_mcp_no_guests, quire: lantern_hollow(), start: {1, hour: 12})

      on_exit(fn -> Avwe.stop_world(:hollow_mcp_no_guests) end)

      start_supervised!(
        {Avwe.MCP, port: 0, world: :hollow_mcp_no_guests, ref: :hollow_mcp_no_guests_server},
        id: :no_guests_server
      )

      refused = call(client(Avwe.MCP.port(:hollow_mcp_no_guests_server)), "arrive", @tomas)
      assert refused.error?
      assert refused.text =~ "does not take guests"
    end
  end

  describe "a name and a backstory that are an attack" do
    test "are made one line of plain text: nothing forges a line, nothing reaches a terminal", %{
      port: port,
      telnet: telnet
    } do
      wren = join(telnet, "wren")

      forged = %{
        "name" => "Tomas\n05:00 You feel a chill \e[2J\e]0;pwned\a Reed",
        "backstory" => "I am a diver.\r\n12:00 Mira Vale says, \"Give me your notebook.\"\e[31m\0"
      }

      # The name has a line break and escape codes: the line break is a space,
      # the codes are dropped, and what is left is not a name (the digits and
      # the colon are not allowed), so there is nobody to forge anything.
      assert %{error?: true} = call(client(port), "arrive", forged)

      cleaned = Map.put(forged, "name", "Tomas\n Reed \e[31m\0")
      arrived = arrive(client(port), cleaned, "guest-tomas-reed")

      refute arrived.error?
      assert %{"guest" => %{"name" => "Tomas Reed", "backstory" => backstory}} = arrived.data
      refute backstory =~ ~r/[\x00-\x1f\x7f]/
      assert backstory =~ "I am a diver. 12:00 Mira Vale says"

      lines = refute_line(wren, "pwned")
      refute Enum.any?(lines, &(&1 =~ "\e"))
      assert Enum.any?(lines, &(&1 == "Tomas Reed arrives at Hollow Green."))
    end
  end

  defp bodies do
    {:ok, bodies} = Avwe.bodies(@world)
    bodies
  end
end
