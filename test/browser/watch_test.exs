defmodule Avwe.Browser.WatchTest do
  @moduledoc """
  The watch page in a real browser: Chromium, driven by Playwright, against the
  endpoint over a real socket. What the other tests cannot see: that the script
  loads under the content security policy, that the hook draws the valley on the
  canvas in the colours the server gave it, that the buttons, the wheel and the
  mouse do what they say, and which cell a click fell on. Run with
  `mix test --only playwright` (see the README for the install).

  The Ember Reach an hour before the river's source fails, on a manual clock
  that these tests do not move. The page's own state is read from what the hook
  writes on the canvas (`data-drawn-*`), and the canvas is read pixel by pixel
  where its colours are the point, against what the scene says they should be
  (`Avwe.Test.PageData`). The river's drying, watched from a page and from
  telnet, is `watch_river_test.exs`.
  """

  use PhoenixTest.Playwright.Case, async: false

  import Avwe.Test.BrowserPage
  import Avwe.Test.Fixtures, only: [ember_reach_opts: 1]

  alias Avwe.GroundCache
  alias Avwe.Test.{BrowserConsole, PageData}

  @moduletag :playwright

  @world :ember_browser
  @page "/watch/ember_browser"

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: {812, day: 200, hour: 14}))
    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.world(terrain)

    # Whatever the page says to the console, an error fails the test.
    BrowserConsole.clear()

    on_exit(fn ->
      assert BrowserConsole.errors() == [], "the page wrote errors to the browser's console"
    end)
  end

  defp thing(scene, id), do: Enum.find(scene["things"], &(&1["id"] == id))

  defp cell(thing), do: thing["cell"] |> List.to_tuple()

  # Whether the key to the heat is shown.
  defp heat_key(conn),
    do: js(conn, "getComputedStyle(document.querySelector('.heat-ramp')).display")

  # Two colours as near as a canvas's rounding keeps them.
  defp close?({r1, g1, b1}, {r2, g2, b2}),
    do: abs(r1 - r2) <= 2 and abs(g1 - g2) <= 2 and abs(b1 - b2) <= 2

  # A number the hook wrote: "96" or "13.4".
  defp number(text) do
    {number, ""} = Float.parse(text)
    number
  end

  # Where the window's top left is, in cells.
  defp pan(conn),
    do: conn |> drawn() |> Map.fetch!("drawnPan") |> String.split(",") |> Enum.map(&number/1)

  defp visit_valley(conn), do: conn |> visit(@page) |> assert_has("#world[data-drawn-ground]")

  test "the lobby leads to a page that draws the whole valley", %{conn: conn} do
    conn =
      conn
      |> visit("/")
      |> assert_has("h2", text: "The Ember Reach")
      |> click_link("Watch The Ember Reach")
      |> assert_has("body .phx-connected")
      |> assert_has("#world[data-drawn-ground]")
      |> assert_has(".clock", text: "812 AR, day 200, 14:00")

    state = drawn(conn)
    scene = scene(conn)

    # The hook drew what the server sent: the whole valley, at the size that fits.
    assert state["drawnGround"] == "256x256"
    assert state["drawnZoom"] == "0"
    assert state["drawnPan"] == "0,0"
    assert state["drawnOverlays"] == "water,smoke"
    assert state["drawnTime"] == to_string(scene["time"])
    assert state["drawnReaches"] == "23"
    assert state["drawnSilent"] == "0"

    assert String.split(state["drawnThings"], ",") ==
             scene["things"] |> Enum.map(& &1["id"]) |> Enum.sort()

    # And it put the ground on the canvas: most of the valley is lit.
    {width, height} =
      {js(conn, "document.querySelector('#world').width"),
       js(conn, "document.querySelector('#world').height")}

    assert lit(conn) > width * height * 0.9
  end

  test "the buttons switch the river, the heat and the smoke, and the canvas follows", %{
    conn: conn
  } do
    conn = visit_valley(conn)
    scene = scene(conn)
    [source | _] = PageData.bed_samples(ground(conn), scene)
    banks = PageData.bank_samples(ground(conn), scene, 8)
    flowing = PageData.rgb(scene["overlays"]["water"]["colors"]["flowing"])

    # To begin with, the river and the smoke: a reach that runs is the colour of
    # running water, and there is no smoke yet to cover it. The heat's key is
    # not shown while the heat is not.
    assert drawn(conn)["drawnOverlays"] == "water,smoke"
    assert drawn(conn)["drawnPuffs"] == "0"
    assert pixels(conn, [source]) == [flowing]
    assert heat_key(conn) == "none"
    under = pixels(conn, banks)

    # The heat: each bank cell is drawn in the colour of its level, four fifths
    # over what was there, and the key to the colours appears.
    conn =
      conn
      |> click_button("#overlay-heat", "Heat")
      |> assert_has("#overlay-heat[aria-pressed='true']")
      |> assert_has("#world[data-drawn-overlays='water,heat,smoke']")

    assert heat_key(conn) != "none"
    levels = PageData.levels(scene, banks)

    for {{cell, shown}, was} <- Enum.zip(Enum.zip(banks, pixels(conn, banks)), under) do
      expected = scene |> PageData.heat_rgb(levels[cell]) |> PageData.heat_over(was)

      assert close?(shown, expected),
             "the canvas shows #{inspect(shown)} at #{inspect(cell)} (level #{levels[cell]}), the heat over #{inspect(was)} is #{inspect(expected)}"
    end

    screenshot(conn, "watch-heat.png", full_page: true)

    # Pressed again, the heat is gone, and the canvas is as it was.
    conn =
      conn
      |> click_button("#overlay-heat", "Heat")
      |> assert_has("#overlay-heat[aria-pressed='false']")
      |> assert_has("#world[data-drawn-overlays='water,smoke']")

    assert pixels(conn, banks) == under
    assert heat_key(conn) == "none"

    # Without the river, the bed is the dry bed's, and without the smoke there
    # is nothing drawn over the valley at all.
    conn =
      conn
      |> click_button("#overlay-water", "River")
      |> assert_has("#overlay-water[aria-pressed='false']")
      |> assert_has("#world[data-drawn-overlays='smoke']")

    refute pixels(conn, [source]) == [flowing]

    conn
    |> click_button("#overlay-smoke", "Smoke")
    |> assert_has("#overlay-smoke[aria-pressed='false']")
    |> assert_has("#world[data-drawn-overlays='']")
  end

  test "the zoom buttons, the wheel and the whole-valley button set the window", %{conn: conn} do
    conn = visit_valley(conn)
    whole = cell_pixels(conn)
    middle = %{x: js(conn, "document.querySelector('#world').clientWidth") / 2, y: 200}

    zoom = fn ->
      state = drawn(conn)
      {String.to_integer(state["drawnZoom"]), number(state["drawnCellPixels"])}
    end

    assert {0, size} = zoom.()
    assert_in_delta size, whole, 0.1

    # Each step doubles the cell, up to eight times the size that fits.
    for step <- 1..3 do
      click_button(conn, "#zoom-in", "Zoom in")
      assert_has(conn, "#world[data-drawn-zoom='#{step}']")
      assert {^step, size} = zoom.()
      assert_in_delta size, whole * Integer.pow(2, step), 0.1
    end

    click_button(conn, "#zoom-in", "Zoom in")
    assert {3, _size} = zoom.()

    click_button(conn, "#zoom-out", "Zoom out")
    click_button(conn, "#zoom-out", "Zoom out")
    assert_has(conn, "#world[data-drawn-zoom='1']")

    # The wheel does the same around the cursor; a trackpad's burst of turns in
    # a moment is one step, and a turn a moment later is another.
    wheel(conn, middle, -100, 2)
    assert_has(conn, "#world[data-drawn-zoom='2']")
    Process.sleep(300)
    wheel(conn, middle, 100)
    assert_has(conn, "#world[data-drawn-zoom='1']")

    conn
    |> click_button("#zoom-fit", "Whole valley")
    |> assert_has("#world[data-drawn-zoom='0']")
    |> assert_has("#world[data-drawn-pan='0,0']")
  end

  test "a drag pans the valley that has been zoomed, and is not a click", %{conn: conn} do
    conn = visit_valley(conn)
    click_button(conn, "#zoom-in", "Zoom in")
    click_button(conn, "#zoom-in", "Zoom in")
    assert_has(conn, "#world[data-drawn-zoom='2']")
    before = drawn(conn)["drawnPan"]
    [x, y] = pan(conn)

    # Dragging the map left and up shows what is to the right and below.
    drag_across(conn, %{x: 400, y: 300}, %{x: 300, y: 240})
    refute_has(conn, "#world[data-drawn-pan='#{before}']")
    [x2, y2] = pan(conn)
    assert x2 > x and y2 > y

    # And it picked nothing: the drag was not a click.
    assert_has(conn, "#picked", text: "Click a person, a hearth or a place.")
  end

  test "a click on a place names what is there, and a click on nothing says so", %{conn: conn} do
    conn = visit_valley(conn)
    scene = scene(conn)

    conn
    |> click_at(position(conn, scene |> thing("ember-reach") |> cell()))
    |> assert_has("#picked",
      text:
        "Mira Vale (person), on its routine; the kiln-house hearth (cold hearth); Ember Reach (place)."
    )

    conn
    |> click_at(position(conn, {5, 5}))
    |> assert_has("#picked", text: "Nothing there.")
  end
end
