defmodule AvweWeb.WatchLiveTest do
  use Avwe.Test.WebCase, async: false

  alias Avwe.{GroundCache, Repr}

  @world :ember_page
  @hollow :hollow_page
  @mira "mira-vale"

  # The Ember Reach an hour before the source fails, on a manual clock: stepped
  # from the test, a minute a step, as a live one goes.
  defp ember do
    {:ok, _pid} =
      Avwe.start_world(@world, ember_reach_opts(start: {812, day: 200, hour: 14}))

    on_exit(fn -> Avwe.stop_world(@world) end)
    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.world(terrain)
    :ok
  end

  defp path(world \\ @world), do: "/watch/#{world}"

  defp sessions, do: DynamicSupervisor.count_children(Avwe.Sessions).active

  # What the page gave its canvas, as the hook reads it.
  defp attribute(view, name) do
    view |> element("#world") |> render() |> LazyHTML.from_fragment() |> LazyHTML.attribute(name)
  end

  defp ground_of(view), do: view |> attribute("data-ground") |> hd() |> Jason.decode!()
  defp scene_of(view), do: view |> attribute("data-scene") |> hd() |> Jason.decode!()

  defp silent(scene), do: Enum.count(scene["overlays"]["water"]["reaches"], & &1["silent"])
  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()
  defp log(view), do: view |> element("#log") |> render() |> text()
  defp picked(view), do: view |> element("#picked") |> render() |> text() |> String.trim()
  defp thing(scene, id), do: Enum.find(scene["things"], &(&1["id"] == id))

  # Steps the world a minute at a time, and waits for the page to have heard of
  # the last.
  defp minutes(view, count) do
    for _minute <- 1..count, do: Avwe.step(@world, 1)
    {:ok, time} = Avwe.snapshot(@world) |> then(fn {:ok, snapshot} -> {:ok, snapshot.time} end)
    assert eventually(fn -> scene_of(view)["time"] == time end, 5_000)
  end

  describe "joining" do
    setup do
      ember()
    end

    test "answers a plain request with the page, joining, and starts no session", %{conn: conn} do
      before = sessions()

      conn = get(conn, path())

      assert html = html_response(conn, 200)
      assert html =~ "Joining The Ember Reach..."
      assert html =~ ~s(phx-hook="WorldCanvas")
      refute html =~ "data-scene"
      assert sessions() == before
    end

    test "gives the canvas the ground and the scene once its socket joins", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)

      ground = ground_of(view)
      assert ground["width"] == 256 and ground["height"] == 256
      assert length(ground["rows"]) == 256
      assert length(ground["reaches"]) == 23
      assert ground["legend"]["grass"]["glyph"]["color"] == Repr.glyph(:grass).color

      scene = scene_of(view)

      assert Enum.sort(Enum.map(scene["things"], & &1["kind"]) |> Enum.uniq()) ==
               ~w(body hearth hearth_burning place)

      assert thing(scene, @mira)["holder"] == nil
      assert length(scene["overlays"]["water"]["reaches"]) == 23
      assert silent(scene) == 0
      assert length(scene["overlays"]["heat"]["rows"]) == 256
    end

    test "says where and when: the world's name and its clock", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())

      assert has_element?(view, "h1", "The Ember Reach")
      assert has_element?(view, ".where", "Watching")
      assert has_element?(view, ".clock", "812 AR, day 200, 14:00")
      assert page_title(view) =~ "Watching The Ember Reach"
    end

    test "holds nothing: every body is free, and the page's session goes with it", %{conn: conn} do
      before = sessions()
      {:ok, view, _html} = live(conn, path())
      assert sessions() == before + 1

      {:ok, bodies} = Avwe.bodies(@world)
      assert Enum.all?(bodies, &(&1.taken == false))

      GenServer.stop(view.pid)
      assert eventually(fn -> sessions() == before end, 5_000)
    end

    test "is watched by any number of pages, each with its own session", %{conn: conn} do
      before = sessions()
      {:ok, one, _html} = live(conn, path())
      {:ok, two, _html} = live(build_conn_like(conn), path())
      assert sessions() == before + 2

      GenServer.stop(one.pid)
      assert eventually(fn -> sessions() == before + 1 end, 5_000)
      assert scene_of(two)["time"]
    end

    test "sends somebody who asks for a world that is not running to the lobby", %{conn: conn} do
      {:ok, _lobby, html} = conn |> live(path("nowhere")) |> follow_redirect(conn, ~p"/")

      assert html =~ "That world is not running."
    end
  end

  describe "what it draws" do
    setup do
      ember()
    end

    test "follows the world: a scene with each step that changes it, and the ground once", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      ground = view |> attribute("data-ground") |> hd()
      first = scene_of(view)

      minutes(view, 30)

      later = scene_of(view)
      assert later["time"] > first["time"]
      assert has_element?(view, ".clock", "14:30")
      # The ground is the page's from the first, and is not sent again.
      assert view |> attribute("data-ground") |> hd() == ground
    end

    test "has the river fall silent from the source down as the source fails and the river drains",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      assert silent(scene_of(view)) == 0

      counts =
        for _hour <- 1..4 do
          minutes(view, 45)
          silent(scene_of(view))
        end

      assert counts == Enum.sort(counts)
      assert List.last(counts) == 23
      assert Enum.uniq(counts) |> length() > 2

      flags = Enum.map(scene_of(view)["overlays"]["water"]["reaches"], & &1["silent"])
      assert Enum.all?(flags)
    end

    test "tells in its log what the telnet watcher is told, in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)

      minutes(view, 4 * 60)

      lines =
        for line <- [
              "The spring stops welling up.",
              "The river falls silent near The Source.",
              "The river falls silent near The Dry Bend.",
              "The river falls silent near Ember Reach.",
              "The river falls silent near Willow Docks."
            ] do
          assert eventually(fn -> log(view) =~ line end, 5_000), line
          log(view) |> :binary.match(line) |> elem(0)
        end

      assert lines == Enum.sort(lines)
    end

    test "keeps the last two hundred lines of its log", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())

      # A hearth lit and put out gives two lines each time; the log is bounded
      # however long the page is open.
      for n <- 1..130 do
        send(
          view.pid,
          {:avwe_percepts, session_of_view(view),
           [%{summary: "Line #{n}."}, %{summary: "More #{n}."}]}
        )
      end

      assert eventually(fn -> log(view) =~ "More 130." end, 5_000)
      refute log(view) =~ "Line 1."

      assert length(Regex.scan(~r/class="line percept"/, view |> element("#log") |> render())) ==
               200
    end

    test "has the legend of what is in the valley, and the key to the heat", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)

      for name <- ["person", "place", "burning hearth", "grass", "dry river bed"] do
        assert has_element?(view, ".legend li", name), name
      end

      assert has_element?(view, ~s(svg[aria-label="Ground temperature, 0 to 40 °C"]))
      assert has_element?(view, "figure.heat-ramp text", "40 °C")
    end

    test "offers the overlays and the zoom as buttons that the hook answers, the river and the smoke on to begin with",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)

      assert has_element?(view, ~s(#overlay-water[aria-pressed="true"]), "River")
      assert has_element?(view, ~s(#overlay-heat[aria-pressed="false"]), "Heat")
      assert has_element?(view, ~s(#overlay-smoke[aria-pressed="true"]), "Smoke")

      assert dispatched(view, "#overlay-heat") == ["map:overlay", %{"overlay" => "heat"}]
      assert dispatched(view, "#zoom-in") == ["map:zoom", %{"step" => 1}]
      assert dispatched(view, "#zoom-out") == ["map:zoom", %{"step" => -1}]
      assert [event, _detail] = dispatched(view, "#zoom-fit")
      assert event == "map:fit"
    end
  end

  describe "a click on the map" do
    setup do
      ember()
    end

    defp click(view, {x, y}, reach \\ 0),
      do: render_hook(view, "cell", %{"x" => x, "y" => y, "r" => reach})

    test "says who and what is at a cell: a body, with who holds it, and what shares its cell", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), @mira)["cell"]

      click(view, {x, y})

      assert picked(view) ==
               "Mira Vale (person), on its routine; the kiln-house hearth (cold hearth); Ember Reach (place)."
    end

    test "says who holds a body", %{conn: conn} do
      {:ok, _session} = Avwe.connect(@world, body: @mira, controller: :arbor)
      Avwe.step(@world, 2)
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), @mira)["cell"]

      click(view, {x, y})

      assert picked(view) =~ "Mira Vale (person), held by arbor;"
    end

    test "says a burning hearth is, and a place", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), "ashwarden-lodge")["cell"]

      click(view, {x, y})

      assert picked(view) ==
               "The Last Coal (burning hearth); the lodge hearth (cold hearth); Ashwarden Lodge (place)."
    end

    test "finds what is a little way off when told how far a click may miss, the nearest first",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), "the-dry-bend")["cell"]

      click(view, {x + 2, y - 1}, 0)
      assert picked(view) == "Nothing there."

      click(view, {x + 2, y - 1}, 1)
      assert picked(view) == "Nothing there."

      click(view, {x + 2, y - 1}, 2)
      assert picked(view) == "The Dry Bend (place)."
    end

    test "says there is nothing where there is nothing, and keeps a click's reach from none to four cells",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), "the-dry-bend")["cell"]

      click(view, {x + 5, y}, 99)
      assert picked(view) == "Nothing there."

      click(view, {x + 4, y}, 99)
      assert picked(view) == "The Dry Bend (place)."

      click(view, {x, y}, -3)
      assert picked(view) == "The Dry Bend (place)."
    end

    test "picks the nearest cell with anything on it, and of two as near the first in reading order",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      scene = :sys.get_state(view.pid).socket.assigns.scene
      place = Enum.find(scene.things, &(&1.kind == :place))

      # Listed with the farther first, and the later of the two as near before
      # the earlier, so that neither the order of the things nor the farthest
      # within reach can be what makes the pick right.
      things =
        for {id, cell} <- [farther: {11, 13}, later: {12, 10}, first: {10, 10}] do
          %{place | id: "#{id}", name: String.capitalize("#{id}"), cell: cell}
        end

      send(view.pid, {:avwe_scene, session_of_view(view), %{scene | things: things}})

      click(view, {11, 10}, 4)
      assert picked(view) == "First (place)."

      click(view, {11, 12}, 4)
      assert picked(view) == "Farther (place)."
    end

    test "ignores what is not a cell and a reach", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      before = picked(view)

      for params <- [
            %{"x" => "a", "y" => 1, "r" => 0},
            %{"x" => 1, "y" => nil, "r" => 0},
            %{"x" => 1, "y" => 1},
            %{"x" => 1.5, "y" => 1, "r" => 0},
            %{}
          ] do
        render_hook(view, "cell", params)
      end

      assert picked(view) == before
      assert before == "Click a person, a hearth or a place."
    end

    test "is told as text, never as markup", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      [x, y] = thing(scene_of(view), @mira)["cell"]

      html = click(view, {x, y})

      refute html =~ "<script"
      assert html =~ "Mira Vale"
    end
  end

  describe "when the world stops" do
    setup do
      ember()
    end

    test "says so, with a way back, and draws nothing more", %{conn: conn} do
      {:ok, view, _html} = live(conn, path())
      render_async(view)
      before = scene_of(view)

      Avwe.stop_world(@world)

      assert eventually(fn -> has_element?(view, ".notice.error", "has stopped") end, 5_000)
      assert has_element?(view, ~s(.notice a[href="/"]), "Back to the lobby")
      assert scene_of(view) == before
    end
  end

  describe "a world with no map" do
    setup do
      {:ok, _pid} = Avwe.start_world(@hollow, quire: lantern_hollow(), start: {1, hour: 12})
      on_exit(fn -> Avwe.stop_world(@hollow) end)
    end

    test "says it has none to draw, and still has its people and its log", %{conn: conn} do
      {:ok, view, _html} = live(conn, path(@hollow))
      render_async(view)

      assert has_element?(view, ".notice", "Lantern Hollow has no map to draw.")
      assert attribute(view, "data-ground") == []
      scene = scene_of(view)

      assert scene |> Map.fetch!("things") |> Enum.filter(&(&1["kind"] == "body")) |> length() ==
               4

      assert scene["overlays"]["heat"] == nil
      assert scene["overlays"]["water"]["reaches"] == []
      refute has_element?(view, ".map-tools")
      refute has_element?(view, "figure.heat-ramp")
    end
  end

  # What a button does when it is pressed: the event it asks the hook for, and
  # its detail.
  defp dispatched(view, selector) do
    [click] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("phx-click")

    for [name, args] <- Jason.decode!(click), name == "dispatch" do
      [args["event"], args["detail"] || %{}]
    end
    |> hd()
  end

  # The session the page opened, which names its messages.
  defp session_of_view(view), do: :sys.get_state(view.pid).socket.assigns.session

  defp build_conn_like(conn), do: Phoenix.ConnTest.build_conn() |> Map.put(:host, conn.host)
end
