defmodule Avwe.E2E.RiverWatchersTest do
  @moduledoc """
  The done criterion of M2b: a watcher in a browser sees the river's reaches fall
  silent one after another, and the silt cool, as the telnet watcher is told of
  them.

  The Ember Reach on day 200 of 812 AR, an hour before the river's source fails,
  on a manual clock, stepped a few minutes at a time. The telnet watcher is over
  real TCP. The page that watches is the LiveView of `/watch/:world` through its
  endpoint (`Phoenix.LiveViewTest`; its socket is `web_watch_test.exs`, and the
  page in a real browser, drawing the same on a canvas, is
  `test/browser/watch_river_test.exs`). What the silt would have been had the
  river run on is a second world, the same but for a source that never fails.
  """

  use Avwe.Test.WebCase, async: false

  import Avwe.Test.PageData
  import Avwe.Test.TelnetClient, only: [expect: 2]

  alias Avwe.{GroundCache, Session, WorldScene}
  alias Avwe.Test.TelnetClient

  # Hours of world time, stepped for real: a busy machine takes its time.
  @moduletag timeout: 180_000

  @world :ember_watchers
  @control :ember_no_miracle
  @start {812, day: 200, hour: 14}

  setup do
    {:ok, _pid} = Avwe.start_world(@world, ember_reach_opts(start: @start))
    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.world(terrain)

    %{telnet: Avwe.Telnet.port(start_supervised!({Avwe.Telnet, port: 0}))}
  end

  # The page has handled everything its session has been sent.
  defp caught_up(view) do
    session = :sys.get_state(view.pid).socket.assigns.session
    _body = Session.body(session)
    render(view)
  end

  # The lines of the page's log, in order.
  defp log_lines(view) do
    view
    |> element("#log")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("li .text")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Steps the world `minutes` at a time, `times` times, and after each gives what
  # the page's water overlay says: whether each reach is silent.
  defp watched(view, minutes, times) do
    for _step <- 1..times do
      Avwe.step(@world, minutes)
      caught_up(view)
      view |> scene() |> silent()
    end
  end

  test "the page draws the reaches falling silent from the source down, and its log is what the telnet watcher is told",
       %{conn: conn, telnet: telnet} do
    # On joining the telnet watcher is told the state of things, which the page
    # shows as its scene and not in its log: what comes after is what happens.
    watcher = TelnetClient.join(telnet, "watch", "You are watching.")
    assert "The Ember is running." in expect(watcher, "The Last Coal is burning.")

    {:ok, view, _html} = live(conn, ~p"/watch/ember_watchers")
    render_async(view)
    assert view |> scene() |> silent() |> Enum.any?() == false

    # Four hours, five minutes at a time. The silent reaches are always the first
    # so many, and there are more of them each time: the river drains from the
    # source down, and is seen to, a few reaches at once and not all at once.
    seen = watched(view, 5, 48)

    for flags <- seen, do: assert(flags == Enum.sort(flags, :desc))
    counts = Enum.map(seen, &Enum.count(&1, fn silent? -> silent? end))
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

    assert Enum.take(log_lines(view), length(told)) == told
  end

  test "the page draws the silt banks cooler than they would have been had the river run on",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/watch/ember_watchers")
    render_async(view)
    banks = view |> ground() |> cells("s")
    assert length(banks) > 2_000

    {:ok, _pid} = Avwe.start_world(@control, ember_reach_opts(start: @start, miracles: []))
    on_exit(fn -> Avwe.stop_world(@control) end)
    {:ok, running} = Avwe.connect(@control, scenes: true)

    start = view |> scene() |> mean_level(banks)

    # Sixteen hours on, the river dry in one world and running in the other.
    for _hour <- 1..16 do
      Avwe.step(@world, 60)
      Avwe.step(@control, 60)
    end

    caught_up(view)
    assert view |> scene() |> silent() |> Enum.all?()
    {:ok, ran_on} = Session.scene(running)

    dried = view |> scene() |> mean_level(banks)
    ran_on = ran_on |> WorldScene.to_map() |> mean_level(banks)

    # The overlay is drawn in whole degrees, and the banks are about three
    # degrees cooler than the river would have kept them.
    assert ran_on - dried >= 2
    assert dried < start
  end
end
