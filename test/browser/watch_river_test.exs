defmodule Avwe.Browser.WatchRiverTest do
  @moduledoc """
  The done criterion of M2b, in a real browser: a watcher in a browser sees the
  river's reaches fall silent one after another, and the silt cool, as the telnet
  watcher is told of them.

  The Ember Reach on day 200 of 812 AR, an hour before the river's source fails,
  on a manual clock stepped a few minutes at a time. The watcher in the browser is
  Chromium on `/watch/:world`, and what it sees is what its canvas shows, pixel by
  pixel. The telnet watcher is over real TCP. What the silt would have been had the
  river run on is a second world, the same but for a source that never fails,
  watched in a second tab. (The same through `Phoenix.LiveViewTest`, which runs in
  every `mix test`, is `test/e2e/river_watchers_test.exs`.)
  """

  use PhoenixTest.Playwright.Case, async: false

  import Avwe.Test.BrowserPage
  import Avwe.Test.Fixtures, only: [ember_reach_opts: 1, eventually: 2]
  import Avwe.Test.TelnetClient, only: [expect: 2]

  alias Avwe.{GroundCache, Overlays}
  alias Avwe.Test.{BrowserConsole, PageData, TelnetClient}
  alias PlaywrightEx.BrowserContext

  @moduletag :playwright
  # Hours of world time, stepped for real, with a browser to keep up: a runner
  # with two slow cores takes its time.
  @moduletag timeout: 180_000

  @world :ember_river_browser
  @control :ember_river_control
  @start {812, day: 200, hour: 14}

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: @start))
    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.world(terrain)

    BrowserConsole.clear()

    on_exit(fn ->
      assert BrowserConsole.errors() == [], "the page wrote errors to the browser's console"
    end)

    %{telnet: Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))}
  end

  # Whether each reach of the river, from the source down, is silent in the world.
  defp truth(world) do
    {:ok, snapshot} = Avwe.snapshot(world)
    snapshot |> Overlays.water() |> Enum.map(& &1.silent)
  end

  defp close?({r1, g1, b1}, {r2, g2, b2}),
    do: abs(r1 - r2) <= 2 and abs(g1 - g2) <= 2 and abs(b1 - b2) <= 2

  defp near?({x, y}, cells, apart),
    do: Enum.any?(cells, fn {cx, cy} -> max(abs(cx - x), abs(cy - y)) < apart end)

  # What the canvas shows once it has drawn the scene it was given and counts
  # `silent` reaches silent.
  defp drawn_with(conn, cells, silent) do
    eventually(
      fn ->
        seen = observe(conn, cells)

        if seen.drawn["drawnSilent"] == to_string(silent) and
             seen.drawn["drawnTime"] == to_string(seen.time),
           do: seen
      end,
      10_000
    )
  end

  # The lines of the page's log, in order.
  defp log_lines(conn) do
    js(
      conn,
      "Array.from(document.querySelectorAll('#log li .text')).map((el) => el.textContent.trim())"
    )
  end

  # Without the smoke, which is drawn over the river and the banks.
  defp watch(conn, world) do
    conn
    |> visit("/watch/#{world}")
    |> assert_has("#world[data-drawn-ground]")
    |> click_button("#overlay-smoke", "Smoke")
    |> assert_has("#world[data-drawn-overlays='water']")
  end

  # A second tab of the browser, which has the same cookies.
  defp another_tab(conn) do
    {:ok, page} = BrowserContext.new_page(conn.context_id, timeout: 5_000)

    {:ok, _} =
      PlaywrightEx.Page.update_subscription(page.guid,
        event: :console,
        enabled: true,
        timeout: 5_000
      )

    PhoenixTest.Playwright.build(%{
      context_id: conn.context_id,
      page_id: page.guid,
      frame_id: page.main_frame.guid,
      tracing_id: conn.tracing_id,
      config: []
    })
  end

  test "the canvas shows the reaches falling silent from the source down, and its log is what the telnet watcher is told",
       %{conn: conn, telnet: telnet} do
    watcher = TelnetClient.join(telnet, "watch", "You are watching.")
    assert "The Ember is running." in expect(watcher, "The Last Coal is burning.")

    conn = watch(conn, @world)
    scene = scene(conn)
    colors = scene["overlays"]["water"]["colors"]
    {flowing, silent} = {PageData.rgb(colors["flowing"]), PageData.rgb(colors["silent"])}
    refute flowing == silent

    # One bed cell of each reach, with nothing but the river drawn over it.
    beds = PageData.bed_samples(ground(conn), scene)
    assert length(beds) == 23

    # Four hours, five minutes at a time. After each, the canvas shows each
    # reach as the world has it: the first so many silent, in the colour of the
    # dry bed, and the rest running, in the colour of the water.
    counts =
      for _step <- 1..48 do
        Avwe.step(@world, 5)
        count = @world |> truth() |> Enum.count(& &1)
        seen = drawn_with(conn, beds, count)

        for {{bed, shown}, k} <- Enum.with_index(Enum.zip(beds, seen.pixels)),
            not near?(bed, seen.things, 3) do
          expected = if k < count, do: silent, else: flowing

          assert close?(shown, expected),
                 "reach #{k} at #{inspect(bed)} shows #{inspect(shown)} with #{count} silent, not #{inspect(expected)}"
        end

        count
      end

    assert counts == Enum.sort(counts)
    assert List.last(counts) == 23
    assert counts |> Enum.uniq() |> length() > 5

    # What the telnet watcher is told of each place, the page's log says, line
    # for line and in order.
    told = expect(watcher, "The river falls silent near Willow Docks.")

    for line <- [
          "The spring stops welling up.",
          "The river falls silent near The Source.",
          "The river falls silent near The Dry Bend.",
          "The river falls silent near Ember Reach.",
          "The river falls silent near Willow Docks."
        ] do
      assert line in told, line
    end

    assert eventually(fn -> Enum.take(log_lines(conn), length(told)) == told end, 10_000)
  end

  test "the canvas shows the silt banks cooler than they would have been had the river run on",
       %{conn: conn} do
    {:ok, _pid} = Avwe.start_world(@control, ember_reach_opts(start: @start, miracles: []))
    on_exit(fn -> Avwe.stop_world(@control) end)

    dried = watch(conn, @world)
    running = conn |> another_tab() |> watch(@control)
    banks = dried |> ground() |> PageData.cells("s")
    assert length(banks) > 2_000
    start = dried |> scene() |> PageData.mean_level(banks)

    # Sixteen hours on, the river dry in one world and running in the other.
    for _hour <- 1..16 do
      Avwe.step(@world, 60)
      Avwe.step(@control, 60)
    end

    for {page, world} <- [{dried, @world}, {running, @control}] do
      {:ok, %{time: time}} = Avwe.snapshot(world)
      assert eventually(fn -> scene(page)["time"] == time end, 10_000)
    end

    # In the data the page was given, the banks are cooler by the degrees a
    # river's seepage keeps them warm.
    cooled = dried |> scene() |> PageData.mean_level(banks)
    kept = running |> scene() |> PageData.mean_level(banks)
    assert kept - cooled >= 2
    assert cooled < start

    # And on the canvas: with the heat drawn, each page shows each of its banks
    # in the colour of the level it was given, four fifths over what was there.
    for page <- [dried, running] do
      scene = scene(page)
      samples = PageData.bank_samples(ground(page), scene, 8)
      levels = PageData.levels(scene, samples)
      before = observe(page, samples)

      page
      |> click_button("#overlay-heat", "Heat")
      |> assert_has("#world[data-drawn-overlays='water,heat']")

      seen = observe(page, samples)
      assert seen.time == before.time

      for {{cell, shown}, was} <- Enum.zip(Enum.zip(samples, seen.pixels), before.pixels),
          not near?(cell, seen.things, 3) do
        expected = scene |> PageData.heat_rgb(levels[cell]) |> PageData.heat_over(was)

        assert close?(shown, expected),
               "the canvas shows #{inspect(shown)} at #{inspect(cell)} (level #{levels[cell]}), the heat over #{inspect(was)} is #{inspect(expected)}"
      end
    end
  end
end
