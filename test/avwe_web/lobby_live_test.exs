defmodule AvweWeb.LobbyLiveTest do
  use Avwe.Test.WebCase, async: false

  @world :hollow_lobby

  describe "with a world running" do
    setup do
      {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
      on_exit(fn -> Avwe.stop_world(@world) end)
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

    test "shows a body somebody holds as being played", %{conn: conn} do
      {:ok, _session} = Avwe.connect(@world, body: "wren", controller: :arbor)
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "li.taken", "Wren")
      assert has_element?(view, "li.taken .state", "(being played)")
      refute has_element?(view, "li.taken", "Tamsin")
    end

    test "looks again when it is told to, as bodies are taken and freed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "li.taken")

      {:ok, session} = Avwe.connect(@world, body: "pell", controller: :arbor)
      refute has_element?(view, "li.taken")

      send(view.pid, :refresh)
      assert has_element?(view, "li.taken", "Pell")

      Avwe.Session.close(session)
      send(view.pid, :refresh)
      refute has_element?(view, "li.taken")
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

    test "follows worlds as they start and stop", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "h2", "The Ember Reach")

      {:ok, _pid} = Avwe.start_world(:ember_lobby, ember_reach_opts())
      on_exit(fn -> Avwe.stop_world(:ember_lobby) end)
      send(view.pid, :refresh)

      assert has_element?(view, "h2", "The Ember Reach")
      assert has_element?(view, "h2", "Lantern Hollow")
      assert has_element?(view, "li.body", "Mira Vale")

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
