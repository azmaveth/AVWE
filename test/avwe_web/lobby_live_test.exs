defmodule AvweWeb.LobbyLiveTest do
  use Avwe.Test.WebCase, async: false

  @world :hollow_lobby

  describe "with a world running" do
    setup do
      {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
      on_exit(fn -> Avwe.stop_world(@world) end)

      # The registry of pages is shared by every test, and the last test's pages
      # are still being cleared out of it as this one begins, so each test has
      # browsers of its own.
      unique = System.unique_integer([:positive])
      %{mine: "mine-#{unique}", yours: "yours-#{unique}"}
    end

    test "lists the world with its tagline and the time, and each body with who it is", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Lantern Hollow"
      assert has_element?(view, ".tagline", "A test village, small enough to hear across.")
      assert has_element?(view, ".time", "12:00")

      for {name, description} <- [
            {"Odo", "A watchman who lives in the tower."},
            {"Pell", "A miller who lives by the pond."},
            {"Tamsin", "A weaver who lives on the green."},
            {"Wren", "A lamplighter who lives on the green."}
          ] do
        assert has_element?(view, "li.body", name)
        assert has_element?(view, "li.body .description", description)
      end
    end

    test "offers a free body as a link to its page, which a click opens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(a[href="/play/hollow_lobby/wren"]), "Wren")

      {:ok, _page, html} =
        view |> element("a", "Wren") |> render_click() |> follow_redirect(conn)

      assert html =~ "You are Wren, at Hollow Green."
    end

    test "offers the world to watch, which a click opens, and which takes nobody's body",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(a[href="/watch/hollow_lobby"]), "Watch Lantern Hollow")
      assert has_element?(view, ".watch .state", "see everything, and take no part")

      {:ok, page, html} =
        view
        |> element(~s(a[href="/watch/hollow_lobby"]))
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Lantern Hollow"
      assert has_element?(page, "canvas#world")

      {:ok, bodies} = Avwe.bodies(@world)
      assert Enum.all?(bodies, &(not &1.taken))
    end

    test "shows a body somebody holds, and does not offer it", %{conn: conn} do
      {:ok, _session} = Avwe.connect(@world, body: "wren", controller: :arbor)
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "li.taken", "Wren")
      assert has_element?(view, "li.taken .state", "(being played)")
      refute has_element?(view, "a", "Wren")
      assert has_element?(view, "a", "Tamsin")
    end

    test "looks again when it is told to, as bodies are taken and freed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "li.taken")

      {:ok, session} = Avwe.connect(@world, body: "pell", controller: :arbor)
      refute has_element?(view, "li.taken")

      send(view.pid, :refresh)
      assert has_element?(view, "li.taken", "Pell")

      # The registry lets go of a session's lease a moment after the session
      # has stopped, so the lobby may need to look again.
      Avwe.Session.close(session)

      assert eventually(fn ->
               send(view.pid, :refresh)
               not has_element?(view, "li.taken")
             end)

      assert has_element?(view, "a", "Pell")
    end

    test "looks again by itself while it is open", %{conn: conn} do
      Application.put_env(:avwe, :lobby_refresh_ms, 10)
      on_exit(fn -> Application.put_env(:avwe, :lobby_refresh_ms, nil) end)

      {:ok, view, _html} = live(conn, ~p"/")
      {:ok, _odo} = Avwe.connect(@world, body: "odo", controller: :arbor)
      assert eventually(fn -> has_element?(view, "li.taken", "Odo") end)

      # And again, and again: each look arranges the next.
      {:ok, _pell} = Avwe.connect(@world, body: "pell", controller: :arbor)
      assert eventually(fn -> has_element?(view, "li.taken", "Pell") end)
    end

    test "offers a body that a page of this browser holds as its own, and takes it over",
         %{conn: conn, mine: mine} do
      Application.put_env(:avwe, :play_retry_ms, 2_000)
      on_exit(fn -> Application.put_env(:avwe, :play_retry_ms, 0) end)

      browser = in_browser(conn, mine)
      {:ok, old, _html} = live(browser, ~p"/play/hollow_lobby/wren")
      {:ok, view, _html} = live(browser, ~p"/")

      assert has_element?(view, "li.yours .state", "open on another page of this browser")
      assert has_element?(view, ~s(li.yours a[href="/play/hollow_lobby/wren"]), "Wren")
      refute has_element?(view, "li.taken")

      {:ok, page, html} =
        view |> element("a", "Wren") |> render_click() |> follow_redirect(browser)

      assert html =~ "You are Wren, at Hollow Green."
      assert has_element?(page, "#look p", "You are Wren, at Hollow Green.")
      assert_redirect(old, "/", 5_000)
    end

    test "shows it as taken to a browser whose pages do not hold it",
         %{conn: conn, mine: mine, yours: yours} do
      {:ok, _page, _html} = live(in_browser(conn, mine), ~p"/play/hollow_lobby/wren")
      {:ok, view, _html} = live(in_browser(conn, yours), ~p"/")

      assert has_element?(view, "li.taken", "Wren")
      assert has_element?(view, "li.taken .state", "(being played)")
      refute has_element?(view, "li.yours")
      refute has_element?(view, "a", "Wren")
    end

    test "shows what no page holds as taken, to every browser, though it has pages of its own",
         %{conn: conn, mine: mine} do
      {:ok, _session} = Avwe.connect(@world, body: "pell", controller: :arbor)
      {:ok, _page, _html} = live(in_browser(conn, mine), ~p"/play/hollow_lobby/wren")
      {:ok, view, _html} = live(in_browser(conn, mine), ~p"/")

      assert has_element?(view, "li.taken", "Pell")
      refute has_element?(view, "a", "Pell")
      assert has_element?(view, "li.yours", "Wren")
    end

    test "shows a body as the browser's own when it looks again, once its page has taken it",
         %{conn: conn, mine: mine} do
      browser = in_browser(conn, mine)
      {:ok, view, _html} = live(browser, ~p"/")
      refute has_element?(view, "li.yours")

      {:ok, _page, _html} = live(browser, ~p"/play/hollow_lobby/wren")
      send(view.pid, :refresh)

      assert has_element?(view, "li.yours", "Wren")
    end

    test "follows worlds as they start and stop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "h2", "The Ember Reach")

      {:ok, _pid} = Avwe.start_world(:ember_lobby, ember_reach_opts())
      on_exit(fn -> Avwe.stop_world(:ember_lobby) end)
      send(view.pid, :refresh)

      assert has_element?(view, "h2", "The Ember Reach")
      assert has_element?(view, "h2", "Lantern Hollow")
      assert has_element?(view, ~s(a[href="/play/ember_lobby/mira-vale"]), "Mira Vale")

      Avwe.stop_world(:ember_lobby)
      send(view.pid, :refresh)
      refute has_element?(view, "h2", "The Ember Reach")
    end
  end

  describe "with no world running" do
    test "says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ".empty", "No worlds are running right now. Come back later.")
      refute has_element?(view, "section.world")
    end
  end
end
