defmodule Avwe.Browser.PlayTest do
  @moduledoc """
  The play page in a real browser: Chromium, driven by Playwright, against the
  endpoint over a real socket. What the other tests cannot see: that the script
  loads under the content security policy, that the hook draws the scene on the
  canvas and says which cell a click fell on, and what a reload and a second tab
  do. Run with `mix test --only playwright` (see the README for the install).

  Lantern Hollow at noon on a manual clock, stepped from the test as a player's
  waiting would be. Wren and Tamsin are on Hollow Green, Pell at the Mill Pond a
  few cells east. The page's own state is read from what the hook writes on the
  canvas (`data-drawn-*`) and not from pixels, except once, to see that
  something was drawn.
  """

  use PhoenixTest.Playwright.Case, async: false

  import Avwe.Test.Fixtures, only: [lantern_hollow: 0, eventually: 1]

  alias Avwe.{GroundCache, Session}
  alias Avwe.Test.BrowserConsole
  alias PlaywrightEx.{Browser, BrowserContext, Frame, Page}

  @moduletag :playwright

  @world :hollow_browser
  @page "/play/hollow_browser/wren"
  @terrain [clay: [{"hollow-green", radius_cells: 3}]]
  @fire_pit [
    id: "green-fire-pit",
    at: "hollow-green",
    name: "the fire pit on the green",
    fuel_kg: 8.0,
    power_w: 5_000.0
  ]

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world,
        quire: lantern_hollow(),
        start: {1, hour: 12},
        terrain: @terrain,
        hearths: [@fire_pit]
      )

    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.fetch(terrain)

    # Whatever the page says to the console, an error fails the test.
    BrowserConsole.clear()

    on_exit(fn ->
      assert BrowserConsole.errors() == [], "the page wrote errors to the browser's console"
    end)
  end

  # What the page works out and the browser does

  # Evaluates JavaScript in the page and gives back what it returns.
  defp js(conn, expression) do
    {:ok, value} = Frame.evaluate(conn.frame_id, expression: expression, timeout: 5_000)
    value
  end

  # What the hook wrote on the canvas once it had drawn (`data-drawn-*`).
  defp drawn(conn), do: js(conn, "({...document.querySelector('#map').dataset})")

  # The scene the server gave the canvas.
  defp scene(conn), do: js(conn, "JSON.parse(document.querySelector('#map').dataset.scene)")

  defp thing(scene, id), do: Enum.find(scene["things"], &(&1["id"] == id))

  # Where, in the canvas, the middle of a cell is.
  defp pixel(scene, drawn, [x, y]) do
    shown = String.to_integer(drawn["drawnShown"])
    cell = String.to_integer(drawn["drawnCellPixels"])
    [cx, cy] = scene["center"]
    half = (shown - 1) / 2

    %{x: (x - (cx - half) + 0.5) * cell, y: (y - (cy - half) + 0.5) * cell}
  end

  # A mouse click on the canvas, at a place in it.
  defp click_map(conn, position) do
    {:ok, _} = Frame.click(conn.frame_id, selector: "#map", position: position, timeout: 5_000)
    conn
  end

  # Steps the world a minute at a time, as a player who is waiting would, until
  # what the page's log says contains `text`: the page learns of each step a
  # moment after it, and a click or a typed line reaches the world a moment
  # after it was made.
  defp step_until_logged(conn, text, limit \\ 30) do
    logged? = "document.querySelector('#log').textContent.includes(#{Jason.encode!(text)})"

    Enum.reduce_while(1..limit, nil, fn _n, _ ->
      Avwe.step(@world, 1)
      Process.sleep(100)
      if js(conn, logged?), do: {:halt, conn}, else: {:cont, nil}
    end) || flunk("the log never said #{inspect(text)}, in #{limit} steps")
  end

  defp neighbour(body) do
    {:ok, session} = Avwe.connect(@world, body: body, controller: :arbor)
    session
  end

  # Another page of the same browser: a tab, which has the same cookies.
  defp another_tab(conn) do
    {:ok, page} = BrowserContext.new_page(conn.context_id, timeout: 5_000)
    tab(conn.context_id, page, conn.tracing_id)
  end

  # A page of a browser of its own: a new context has no cookies, so it is
  # nobody the first tab's pages belong to.
  defp another_browser(browser_id) do
    base_url = Application.fetch_env!(:phoenix_test, :base_url)
    {:ok, context} = Browser.new_context(browser_id, base_url: base_url, timeout: 5_000)
    on_exit(fn -> BrowserContext.close(context.guid, timeout: 5_000) end)

    {:ok, page} = BrowserContext.new_page(context.guid, timeout: 5_000)
    tab(context.guid, page, context.tracing.guid)
  end

  # What the library gives a test for its one page, made for one more, and what
  # that says to the console is caught as for the first.
  defp tab(context_id, page, tracing_id) do
    {:ok, _} = Page.update_subscription(page.guid, event: :console, enabled: true, timeout: 5_000)

    PhoenixTest.Playwright.build(%{
      context_id: context_id,
      page_id: page.guid,
      frame_id: page.main_frame.guid,
      tracing_id: tracing_id,
      config: []
    })
  end

  test "the lobby leads to a page that draws the map of what Wren can see", %{conn: conn} do
    conn =
      conn
      |> visit("/")
      |> assert_has("h2", text: "Lantern Hollow")
      |> click_link("Wren")
      |> assert_has("body .phx-connected")
      |> assert_has("#map[data-drawn-center]")
      |> assert_has("#look p", text: "You are Wren, at Hollow Green.")

    state = drawn(conn)
    scene = scene(conn)

    # The hook drew what the server sent.
    assert state["drawnCenter"] == Enum.join(scene["center"], ",")
    assert state["drawnRadius"] == "50"
    assert state["drawnLight"] == "1"
    assert state["drawnZoom"] == "near"
    assert String.to_integer(state["drawnCells"]) > 1_000

    things = String.split(state["drawnThings"], ",")
    for id <- ~w(tamsin pell mill-pond hollow-green green-fire-pit), do: assert(id in things)
    refute "odo" in things

    # And put something on the canvas.
    lit =
      js(conn, """
      (() => {
        const c = document.querySelector('#map')
        const data = c.getContext('2d').getImageData(0, 0, c.width, c.height).data
        let lit = 0
        for (let i = 0; i < data.length; i += 4) if (data[i] > 40 || data[i + 1] > 40 || data[i + 2] > 40) lit++
        return lit
      })()
      """)

    assert lit > 500
  end

  test "a click on a place on the map walks there", %{conn: conn} do
    conn = visit(conn, @page) |> assert_has("#map[data-drawn-center]")
    scene = scene(conn)
    pond = thing(scene, "mill-pond")["cell"]
    before = drawn(conn)["drawnCenter"]

    click_map(conn, pixel(scene, drawn(conn), pond))

    conn
    |> step_until_logged("You arrive at Mill Pond.")
    |> assert_has("#log li", text: "You set off toward Mill Pond.")
    |> assert_has("#look p", text: "You are Wren, at Mill Pond.")
    |> assert_has("#map[data-drawn-center='#{Enum.join(pond, ",")}']")
    |> screenshot("play-at-the-pond.png", full_page: true)

    refute Enum.join(pond, ",") == before
  end

  test "a click on somebody names them, and goes nowhere", %{conn: conn} do
    tamsin = neighbour("tamsin")
    {:ok, _ref} = Session.act(tamsin, :walk, params: %{direction: "north", distance_m: 200})
    Avwe.step(@world, 2)

    conn = visit(conn, @page) |> assert_has("#map[data-drawn-center]")
    scene = scene(conn)
    [x, y] = thing(scene, "tamsin")["cell"]
    refute [x, y] == scene["center"]

    click_map(conn, pixel(scene, drawn(conn), [x, y]))

    assert_has(conn, "#log li.reply", text: "Tamsin is there.")
  end

  test "a typed line, sent with Enter, reaches the world, and the line clears", %{conn: conn} do
    conn =
      conn
      |> visit(@page)
      |> assert_has("body .phx-connected")
      |> type("#command-line", "say hello from the browser")
      |> press("#command-line", "Enter")

    step_until_logged(conn, ~s(You say, "hello from the browser"))

    assert eventually(fn -> js(conn, "document.querySelector('#command-line').value") == "" end)
    assert js(conn, "document.activeElement.id") == "command-line"

    # (The library's text match breaks on a double quote in the text, so this
    # is the words inside them.)
    assert_has(conn, "#log li.percept", text: "hello from the browser")
  end

  test "a button does what typing it would: lighting the fire pit", %{conn: conn} do
    conn =
      conn
      |> visit(@page)
      |> assert_has("body .phx-connected")
      |> click_button("Light the fire pit on the green")

    step_until_logged(conn, "You light the fire pit on the green.")

    assert_has(conn, "button", text: "Put out the fire pit on the green")
    refute_has(conn, "button", text: "Light the fire pit on the green")
  end

  test "the wider view shows all that is in sight, and the page keeps it as it changes",
       %{conn: conn} do
    conn = visit(conn, @page) |> assert_has("#map[data-drawn-zoom='near']")
    assert drawn(conn)["drawnShown"] == "41"

    conn =
      conn
      |> click_button("Wider view")
      |> assert_has("#map[data-drawn-zoom='far']")
      |> assert_has("#map-zoom[aria-pressed='true']")

    assert drawn(conn)["drawnShown"] == "101"

    # The page changes under it: a neighbour speaks, and the log and the look move.
    tamsin = neighbour("tamsin")
    {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "still here", volume: :talk})
    step_until_logged(conn, ~s(Tamsin says, "still here"))

    conn
    |> assert_has("#map[data-drawn-zoom='far']")
    |> assert_has("#map-zoom[aria-pressed='true']")
    |> screenshot("play-wider-view.png", full_page: true)

    conn
    |> click_button("Wider view")
    |> assert_has("#map[data-drawn-zoom='near']")
  end

  test "a body somebody else holds is refused in the lobby, with the words telnet uses",
       %{conn: conn} do
    neighbour("wren")

    conn
    |> visit(@page)
    |> assert_has(".notice.error", text: "Wren is already being played. Choose someone else.")
    |> assert_path("/")
    |> assert_has("li.taken", text: "Wren")
  end

  test "reloading takes the body again, every time, though the old page is only letting go",
       %{conn: conn} do
    # A browser keeps the page it is leaving until the new document begins to
    # arrive, so the old page still holds the body when the new request comes:
    # that request must answer at once, and not wait for a body that cannot be
    # let go until it has answered (it did, once, and reloading alternated
    # between refused and accepted). What this holds is that. The wait at the
    # socket, for an old page that is slow to let go, is held by the in-process
    # tests (a real browser on this machine lets go too fast to need it).
    Application.put_env(:avwe, :play_retry_ms, 1_500)
    on_exit(fn -> Application.put_env(:avwe, :play_retry_ms, 0) end)

    conn = visit(conn, @page) |> assert_has("#map[data-drawn-center]")

    conn =
      Enum.reduce(1..4, conn, fn _n, conn ->
        conn
        |> PhoenixTest.Playwright.reload_page()
        |> assert_has("#map[data-drawn-center]")
        |> refute_has(".notice.error")
      end)

    assert_path(conn, @page)
  end

  test "a second tab of the browser takes the body from the first, which goes to the lobby",
       %{conn: conn} do
    Application.put_env(:avwe, :play_retry_ms, 1_500)
    on_exit(fn -> Application.put_env(:avwe, :play_retry_ms, 0) end)

    first = visit(conn, @page) |> assert_has("#map[data-drawn-center]")

    second =
      first
      |> another_tab()
      |> visit(@page)
      |> assert_has("#map[data-drawn-center]")
      |> assert_has("#look p", text: "You are Wren, at Hollow Green.")

    # The first tab is told why, and is in the lobby, where the body is the
    # browser's own to take back.
    first
    |> assert_has(".notice.error",
      text: "Wren is now being played from another page of this browser."
    )
    |> assert_path("/")
    |> visit("/")
    |> assert_has("li.yours", text: "Wren")

    # The second tab is playing: what it types reaches the world.
    second |> type("#command-line", "say still here") |> press("#command-line", "Enter")
    step_until_logged(second, ~s(You say, "still here"))

    # And the body goes back the other way, with a click in the lobby.
    first |> click_link("Wren") |> assert_has("#map[data-drawn-center]")

    second
    |> assert_has(".notice.error",
      text: "Wren is now being played from another page of this browser."
    )
    |> assert_path("/")
  end

  test "a tab of another browser is turned away, and the first tab keeps its body",
       %{conn: conn, browser_id: browser_id} do
    Application.put_env(:avwe, :play_retry_ms, 300)
    on_exit(fn -> Application.put_env(:avwe, :play_retry_ms, 0) end)

    first = visit(conn, @page) |> assert_has("#map[data-drawn-center]")

    browser_id
    |> another_browser()
    |> visit(@page)
    |> assert_has(".notice.error", text: "Wren is already being played. Choose someone else.")
    |> assert_path("/")
    |> assert_has("li.taken", text: "Wren")
    |> refute_has("li.yours")

    first
    |> assert_has("#look p", text: "You are Wren, at Hollow Green.")
    |> refute_has(".notice.error")
    |> assert_path(@page)
  end
end
