defmodule Avwe.E2E.ThreeControllersTest do
  @moduledoc """
  The done criterion of M2: a telnet player, a web player and an MCP player are
  in the world at once, and each perceives the others.

  Lantern Hollow at noon on a manual clock. Wren (telnet) and Tamsin (MCP) are
  on Hollow Green. Odo (the web page) is in the Far Tower, 1.5 km east, out of
  sight and hearing, and walks to them. Telnet is over TCP, MCP over HTTP with
  ArborMCP's client, and the page through its endpoint with `Phoenix.LiveViewTest`
  (its socket and its browser are tested in `web_test.exs` and the Browser job).
  """

  use Avwe.Test.WebCase, async: false

  import Avwe.Test.MCPClient, only: [call: 2, call: 3, calling: 5, step_until_done: 4]
  import Avwe.Test.TelnetClient, only: [expect: 2, refute_line: 2, send_line: 2, sync: 1]

  alias Avwe.{GroundCache, Session}
  alias Avwe.Test.{MCPClient, TelnetClient}

  @world :hollow_three
  @ref :hollow_three_mcp
  @terrain [clay: [{"hollow-green", radius_cells: 3}]]

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12}, terrain: @terrain)

    on_exit(fn -> Avwe.stop_world(@world) end)
    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.fetch(terrain)

    start_supervised!({Avwe.MCP, port: 0, world: @world, ref: @ref})
    telnet = Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))
    %{mcp: Avwe.MCP.port(@ref), telnet: telnet}
  end

  defp mcp_player(port, body) do
    client = MCPClient.connect(port)
    on_exit(fn -> stop_quietly(client) end)
    refute call(client, "join", %{"body" => body}).error?
    client
  end

  defp stop_quietly(client) do
    MCPClient.close(client)
  catch
    :exit, _gone -> :ok
  end

  # Waits for the page's session to have handled every step so far.
  defp heard(view, body) do
    _body = @world |> session_of(body) |> Session.body()
    render(view)
  end

  defp type(view, line), do: view |> form("#command", %{line: line}) |> render_submit()

  defp scene_of(view) do
    view
    |> element("#map")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-scene")
    |> hd()
    |> Jason.decode!()
  end

  defp thing(scene, id), do: Enum.find(scene["things"], &(&1["id"] == id))

  # Steps the world a minute at a time until the page's scene says `done`.
  defp step_until(view, body, done, limit \\ 40) do
    Enum.reduce_while(1..limit, nil, fn _n, _scene ->
      Avwe.step(@world, 1)
      heard(view, body)
      scene = scene_of(view)
      if done.(scene), do: {:halt, scene}, else: {:cont, nil}
    end) || flunk("the scene never showed it, in #{limit} steps")
  end

  test "each of the three perceives the others, and they all see the body let go", %{
    conn: conn,
    mcp: mcp,
    telnet: telnet
  } do
    wren = TelnetClient.join(telnet, "wren")
    tamsin = mcp_player(mcp, "tamsin")
    {:ok, odo, _html} = live(conn, ~p"/play/hollow_three/odo")

    # The lobby says who is in: three held, Pell free.
    {:ok, lobby, _html} = live(Phoenix.ConnTest.recycle(conn), ~p"/")
    assert has_element?(lobby, "li.taken", "Wren")
    assert has_element?(lobby, "li.taken", "Tamsin")
    assert has_element?(lobby, "li.taken", "Odo")
    assert has_element?(lobby, ~s(a[href="/play/hollow_three/pell"]), "Pell")

    # Odo is 150 cells away: the others are out of his sight.
    before = scene_of(odo)
    assert thing(before, "wren") == nil
    assert thing(before, "tamsin") == nil
    assert before["you"]["id"] == "odo"

    # He sets off for the green, by the command line.
    type(odo, "go to hollow green")

    # Within his sight (50 cells at noon) they appear, at the green's cell: the
    # scene shows the other two where they are.
    seen = step_until(odo, "odo", &(thing(&1, "wren") != nil))
    green = thing(seen, "hollow-green")["cell"]
    assert thing(seen, "wren")["cell"] == green
    assert thing(seen, "tamsin")["cell"] == green
    assert thing(seen, "wren")["kind"] == "body"
    assert seen["center"] != green

    # He walks on, a scene a step, and arrives.
    arrived =
      step_until(odo, "odo", &(&1["center"] == &1 |> thing("hollow-green") |> Map.fetch!("cell")))

    assert arrived["center"] == green
    assert has_element?(odo, "#log li.percept", "You arrive at Hollow Green.")
    assert has_element?(odo, "#look p", "You are Odo, at Hollow Green.")
    assert has_element?(odo, "#look p", "Wren is here.")

    # The telnet player and the MCP player are told he arrived.
    expect(wren, "Odo arrives at Hollow Green.")
    assert call(tamsin, "listen").text =~ "Odo arrives at Hollow Green."

    # He speaks, on the page: the others, within earshot, hear it.
    type(odo, "say good morning")
    Avwe.step(@world, 1)
    expect(wren, ~s(Odo says, "good morning"))
    assert call(tamsin, "listen").text =~ ~s(Odo says, "good morning")

    # Wren answers, on telnet: Odo's page and Tamsin hear it.
    send_line(wren, "say good morning, Odo")
    sync(wren)
    Avwe.step(@world, 1)
    heard(odo, "odo")
    assert has_element?(odo, "#log li.percept", ~s(Wren says, "good morning, Odo"))
    assert call(tamsin, "listen").text =~ ~s(Wren says, "good morning, Odo")

    # Tamsin, over MCP, walks to the pond. The scene moves her, and telnet is told.
    task = calling(tamsin, @world, "tamsin", "act", %{"verb" => "go", "target" => "mill-pond"})
    walked = step_until_done(task, @world, "tamsin", 3)
    refute walked.error?
    heard(odo, "odo")
    pond = scene_of(odo) |> thing("mill-pond") |> Map.fetch!("cell")
    assert scene_of(odo) |> thing("tamsin") |> Map.fetch!("cell") == pond
    assert pond != green
    expect(wren, "Tamsin leaves, heading toward Mill Pond.")
    assert has_element?(odo, "#log li.percept", "Tamsin leaves, heading toward Mill Pond.")

    # Odo leaves by the page. His body is free for the routine, in every view.
    type(odo, "quit")
    assert_redirect(odo, ~p"/")
    assert eventually(fn -> not Enum.find(bodies(), &(&1.id == "odo")).taken end)

    {:ok, lobby, _html} = live(Phoenix.ConnTest.recycle(conn), ~p"/")
    assert has_element?(lobby, ~s(a[href="/play/hollow_three/odo"]), "Odo")
    assert has_element?(lobby, "li.taken", "Wren")

    assert call(tamsin, "bodies").text =~
             ~r/- Odo \(id: odo\): free; their routine has them\./

    menu =
      telnet
      |> TelnetClient.connect()
      |> tap(&expect(&1, "Who will you be?"))
      |> expect("watch without a body")

    assert Enum.any?(menu, &(&1 =~ ~r/^  Odo - /))
    assert Enum.any?(menu, &(&1 =~ ~r/^  Wren \(being played\)/))

    # And Wren is told nothing more about him.
    refute_line(wren, "Odo")
  end

  test "somebody who is out of earshot is not heard, whoever is listening", %{
    conn: conn,
    mcp: mcp,
    telnet: telnet
  } do
    wren = TelnetClient.join(telnet, "wren")
    pell = mcp_player(mcp, "pell")
    {:ok, tamsin, _html} = live(conn, ~p"/play/hollow_three/tamsin")

    # Pell is at the pond, 70 m from the green: talk does not carry, a shout does.
    type(tamsin, "say can you hear me")
    Avwe.step(@world, 1)
    expect(wren, ~s(Tamsin says, "can you hear me"))
    refute call(pell, "listen").text =~ "can you hear me"

    type(tamsin, "shout over here")
    Avwe.step(@world, 1)
    expect(wren, ~s(Tamsin shouts, "over here"))
    assert call(pell, "listen").text =~ ~s(Tamsin shouts from the west, "over here")
  end

  defp bodies do
    {:ok, bodies} = Avwe.bodies(@world)
    bodies
  end
end
