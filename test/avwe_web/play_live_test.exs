defmodule AvweWeb.PlayLiveTest do
  use Avwe.Test.WebCase, async: false

  alias Avwe.{GroundCache, Percept, Session}

  @world :hollow_play
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

    # The ground map is built once for a terrain, here, so that no test waits for it.
    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    GroundCache.fetch(terrain)
    :ok
  end

  defp taken?(body) do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == body)).taken
  end

  defp controller(body) do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == body)).controller
  end

  # Somebody who is not on a page: a session that acts, and does not mind its words.
  defp neighbour(body) do
    {:ok, session} = Avwe.connect(@world, body: body, controller: :arbor)
    session
  end

  # Waits for the page's session to have handled every step so far, so that
  # what it heard is on the page.
  defp heard(view, body) do
    _body = @world |> session_of(body) |> Session.body()
    render(view)
  end

  defp type(view, line), do: view |> form("#command", %{line: line}) |> render_submit()

  defp log(view), do: view |> element("#log") |> render() |> text()
  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  # What the page gave its canvas, as the hook reads it.
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

  describe "taking a body" do
    test "takes it when the page connects, and says who and where its body is", %{conn: conn} do
      refute taken?("wren")

      {:ok, view, html} = live(conn, ~p"/play/hollow_play/wren")

      assert taken?("wren")
      assert html =~ "Wren"
      assert has_element?(view, ".where", "Lantern Hollow")
      assert has_element?(view, "#look p", "You are Wren, at Hollow Green.")
      assert has_element?(view, "#look p", "Tamsin is here.")
      assert has_element?(view, ".clock", "1 AR, day 1, 12:00. It is daylight.")
    end

    test "begins its log as telnet does, with the look", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(view, "#log li.reply", "You are Wren, at Hollow Green.")
    end

    test "tells what happened while the body was nobody's once, in the log, and not in the look",
         %{conn: conn} do
      tamsin = neighbour("tamsin")
      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Anybody?", volume: :talk})
      Avwe.step(@world, 1)
      Avwe.step(@world, 5)
      Session.close(tamsin)

      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(view, "#log li.reply", "While you were away:")
      assert has_element?(view, "#log li.reply", ~s(Tamsin says, "Anybody?"))
      refute has_element?(view, "#look", "While you were away")
      refute has_element?(view, "#look", "Anybody?")
    end

    test "does not take it for the plain request that comes first", %{conn: conn} do
      conn = get(conn, ~p"/play/hollow_play/wren")

      assert html_response(conn, 200) =~ "Wren"
      refute taken?("wren")
    end

    test "refuses a body that is held, in the lobby, with the words telnet uses", %{conn: conn} do
      neighbour("wren")

      {:ok, lobby, html} =
        conn |> live(~p"/play/hollow_play/wren") |> follow_redirect(conn, ~p"/")

      assert html =~ "Wren is already being played. Choose someone else."
      assert has_element?(lobby, ".notice.error", "Wren is already being played.")
      assert has_element?(lobby, "li.taken", "Wren")
    end

    test "refuses it with a redirect to the lobby when it is a plain request", %{conn: conn} do
      neighbour("wren")

      conn = get(conn, ~p"/play/hollow_play/wren")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Wren is already being played. Choose someone else."
    end

    test "settles a race for a free body at the socket, and the one who is late is sent back",
         %{conn: conn} do
      conn = get(conn, ~p"/play/hollow_play/wren")
      assert html_response(conn, 200) =~ "Wren"

      neighbour("wren")

      {:ok, lobby, html} = conn |> live() |> follow_redirect(conn, ~p"/")

      assert html =~ "Wren is already being played. Choose someone else."
      assert has_element?(lobby, "li.taken", "Wren")
    end

    test "says so to somebody who asks for a world or a body that is not there", %{conn: conn} do
      {:ok, _lobby, html} =
        conn |> live(~p"/play/nowhere/wren") |> follow_redirect(conn, ~p"/")

      assert html =~ "That world is not running."

      {:ok, _lobby, html} =
        conn |> live(~p"/play/hollow_play/nobody") |> follow_redirect(conn, ~p"/")

      assert html =~ "There is nobody by that name in Lantern Hollow."
    end
  end

  describe "the log" do
    test "shows what happens as lines", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")

      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Good morning", volume: :talk})
      Avwe.step(@world, 1)
      heard(view, "wren")

      assert has_element?(view, "#log li.percept", ~s(Tamsin says, "Good morning"))
    end

    test "shows what is said as text, never as markup", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")
      words = ~s|<script>alert(1)</script> <b onclick="x()">hi</b>|

      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: words, volume: :talk})
      Avwe.step(@world, 1)
      html = heard(view, "wren")

      assert has_element?(view, "#log li", words)
      refute has_element?(view, "#log script")
      refute has_element?(view, "#log b")
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)"
    end

    test "keeps the last two hundred lines", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")

      for n <- 1..210 do
        {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "word #{n}", volume: :talk})
        Avwe.step(@world, 1)
      end

      heard(view, "wren")
      lines = view |> element("#log") |> render() |> String.split("<li") |> length()

      assert lines - 1 == 200
      assert has_element?(view, "#log li", ~s(Tamsin says, "word 210"))
      refute has_element?(view, "#log li", ~s("word 10"))
    end

    test "styles apart what the routine does while the body is yielded, as telnet marks it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      session = session_of(@world, "wren")

      percept = fn type, summary, issuer ->
        %Percept{kind: :progress, type: type, time: 0, summary: summary, issuer: issuer}
      end

      send(
        view.pid,
        {:avwe_percepts, session, [percept.(:action_started, "You set off.", :controller)]}
      )

      assert has_element?(view, "#log li.percept", "You set off.")
      refute has_element?(view, ".notice", "Your routine has you")

      send(
        view.pid,
        {:avwe_percepts, session,
         [
           percept.(:control_released, "You let your routine carry you.", nil),
           percept.(:action_started, "You set off toward Mill Pond.", :autopilot)
         ]}
      )

      assert has_element?(view, "#log li.routine", "You set off toward Mill Pond.")
      assert has_element?(view, "#log li.percept", "You let your routine carry you.")
      assert has_element?(view, ".notice", "Your routine has you; act to take yourself back.")

      send(
        view.pid,
        {:avwe_percepts, session,
         [
           percept.(:control_taken, "You take yourself in hand.", nil),
           percept.(:action_started, "You set off toward Hollow Green.", :controller)
         ]}
      )

      assert has_element?(view, "#log li.percept", "You set off toward Hollow Green.")
      refute has_element?(view, "#log li.routine", "Hollow Green")
      refute has_element?(view, ".notice", "Your routine has you")
    end
  end

  describe "the command line" do
    test "says what is typed, as the world hears it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")

      type(view, "say good morning")
      Avwe.step(@world, 1)

      assert [%Percept{summary: ~s(Wren says, "good morning")}] = percepts(tamsin)
      assert heard(view, "wren") =~ "You say"
    end

    test "answers look, time and help in the log", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      type(view, "time")
      assert has_element?(view, "#log li.reply", "1 AR, day 1, 12:00")

      type(view, "help")
      assert has_element?(view, "#log li.reply", "Commands:")
      assert has_element?(view, "#log li.reply", ~r/quit\s+leave/)
      assert has_element?(view, "#log li.reply", "Lines in grey are what your routine does")

      type(view, "look")
      assert has_element?(view, "#log li.reply", "You see Pell, 70 m to the east.")
    end

    test "refuses what it cannot do in words, and echoes the player's own as text",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      type(view, "go to atlantis")
      assert has_element?(view, "#log li.reply", ~s(You don't know a place called "atlantis".))

      type(view, "<b>dance</b>")

      assert has_element?(
               view,
               "#log li.reply",
               ~s(I don't understand "<b>dance</b>". Type help for a list of commands.)
             )

      refute has_element?(view, "#log b")
    end

    test "takes an empty line for nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      before = log(view)

      type(view, "   ")

      assert log(view) == before
    end

    test "walks to a place, and the look follows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      type(view, "go to mill pond")
      Avwe.step(@world, 3)
      heard(view, "wren")

      assert has_element?(view, "#log li.percept", "You set off toward Mill Pond.")
      assert has_element?(view, "#log li.percept", "You arrive at Mill Pond.")
      assert has_element?(view, "#look p", "You are Wren, at Mill Pond.")
    end

    test "leaves for the lobby at quit, and frees the body", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      type(view, "quit")
      assert_redirect(view, ~p"/")

      assert eventually(fn -> not taken?("wren") end)
    end
  end

  describe "the buttons" do
    test "offer the places the body knows, and a click goes there", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(
               view,
               ~s(button[phx-value-line="go to mill-pond"]),
               "Mill Pond (70 m east)"
             )

      assert has_element?(view, ~s(button[phx-value-line="go to far-tower"]), "Far Tower")
      refute has_element?(view, ~s(button[phx-value-line="go to hollow-green"]))

      view |> element(~s(button[phx-value-line="go to mill-pond"])) |> render_click()
      Avwe.step(@world, 3)
      heard(view, "wren")

      assert has_element?(view, "#look p", "You are Wren, at Mill Pond.")
      assert has_element?(view, ~s(button[phx-value-line="go to hollow-green"]), "Hollow Green")
      refute has_element?(view, ~s(button[phx-value-line="go to mill-pond"]))
    end

    test "light a hearth, and then put it out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(view, "button", "Light the fire pit on the green")
      refute has_element?(view, "button", "Put out the fire pit on the green")

      view |> element(~s(button[phx-value-line="kindle green-fire-pit"])) |> render_click()
      Avwe.step(@world, 1)
      heard(view, "wren")

      assert burning?("green-fire-pit")
      assert has_element?(view, "button", "Put out the fire pit on the green")
      refute has_element?(view, "button", "Light the fire pit on the green")

      view |> element(~s(button[phx-value-line="douse green-fire-pit"])) |> render_click()
      Avwe.step(@world, 1)
      heard(view, "wren")

      refute burning?("green-fire-pit")
      assert has_element?(view, "button", "Light the fire pit on the green")
    end

    test "offer to stop while walking, and to wait", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      refute has_element?(view, ~s(button[phx-value-line="stop"]))
      assert has_element?(view, ~s(button[phx-value-line="wait until dusk"]), "Wait until dusk")

      view |> element(~s(button[phx-value-line="go to far-tower"])) |> render_click()
      Avwe.step(@world, 1)
      heard(view, "wren")
      assert has_element?(view, ~s(button[phx-value-line="stop"]), "Stop")

      view |> element(~s(button[phx-value-line="stop"])) |> render_click()
      Avwe.step(@world, 1)
      heard(view, "wren")
      assert has_element?(view, "#log li.percept", "You stop short of Far Tower.")
      refute has_element?(view, ~s(button[phx-value-line="stop"]))
    end

    test "are only what typing can do: a line sent from a button is read as a typed one",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      render_click(view, "command", %{"line" => "dance"})

      assert has_element?(view, "#log li.reply", ~s(I don't understand "dance".))
    end
  end

  describe "the look" do
    test "shows the world's time when it is read again", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      assert has_element?(view, ".clock", "1 AR, day 1, 12:00")

      Avwe.step(@world, 25)
      send(view.pid, :refresh)

      assert has_element?(view, ".clock", Avwe.now(@world))
      assert has_element?(view, ".clock", "12:25")
    end

    test "is read again by itself while the page is open", %{conn: conn} do
      Application.put_env(:avwe, :play_refresh_ms, 10)
      on_exit(fn -> Application.put_env(:avwe, :play_refresh_ms, nil) end)

      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      Avwe.step(@world, 5)
      assert eventually(fn -> has_element?(view, ".clock", "12:05") end)

      Avwe.step(@world, 5)
      assert eventually(fn -> has_element?(view, ".clock", "12:10") end)
    end
  end

  describe "presence" do
    setup do
      Application.put_env(:avwe, :play_idle_after_ms, 300)
      on_exit(fn -> Application.delete_env(:avwe, :play_idle_after_ms) end)
    end

    test "typing and pressing keep the body in hand, and redrawing the look does not",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      for line <- ["time", "help", "look", "time", "help"] do
        Process.sleep(100)
        type(view, line)
      end

      Avwe.step(@world, 1)
      assert controller("wren") == :human
      refute has_element?(view, ".notice", "Your routine has you")

      # A page that only looks again is not a player who is there.
      for _n <- 1..5 do
        Process.sleep(100)
        send(view.pid, :refresh)
      end

      Avwe.step(@world, 1)
      heard(view, "wren")
      assert controller("wren") == :autopilot
      assert has_element?(view, ".notice", "Your routine has you; act to take yourself back.")

      # Acting takes the body back.
      type(view, "wait")
      Avwe.step(@world, 1)
      heard(view, "wren")
      assert controller("wren") == :human
      refute has_element?(view, ".notice", "Your routine has you")
    end
  end

  describe "the map" do
    test "is given the scene, as the hook reads it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      scene = scene_of(view)

      assert %{"you" => %{"id" => "wren", "name" => "Wren"}, "radius" => 50.0, "size" => 101} =
               scene

      assert thing(scene, "tamsin")["kind"] == "body"
      assert thing(scene, "pell")["kind"] == "body"
      assert thing(scene, "mill-pond")["kind"] == "place"
      assert thing(scene, "mill-pond")["cell"] != scene["center"]
      assert thing(scene, "hollow-green")["cell"] == scene["center"]
      assert is_list(scene["rows"])
      assert scene["legend"]["clay"]["glyph"]["char"] == ":"
    end

    test "offers a wider view, which the page itself switches and the server does not hear of",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(view, ~s(button#map-zoom[aria-pressed="false"]), "Wider view")

      # Switching the view is the page's own: the button only tells the canvas.
      assert html =~ "toggle_attr"
      assert html =~ "map:zoom"
    end

    test "has no wider view to offer before there is a scene", %{conn: conn} do
      html = conn |> get(~p"/play/hollow_play/wren") |> html_response(200)

      refute html =~ "map-zoom"
    end

    test "names its kinds in a legend", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      assert has_element?(view, ".legend li", "clay")
      assert has_element?(view, ".legend li", "person")
      assert has_element?(view, ".legend li", "place")
    end

    test "follows the world: a neighbour who walks is somewhere else in the next scene",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      before = view |> scene_of() |> thing("pell")
      pell = neighbour("pell")

      {:ok, _ref} = Session.act(pell, :go, target: "hollow-green")
      Avwe.step(@world, 3)
      heard(view, "wren")
      moved = view |> scene_of() |> thing("pell")

      assert moved["cell"] != before["cell"]
      assert moved["cell"] == scene_of(view)["center"]
    end

    test "gets a scene with the ground in it when the map of the ground is built later",
         %{conn: conn} do
      cold = :hollow_cold
      seed = System.unique_integer([:positive])

      {:ok, _pid} =
        Avwe.start_world(cold,
          quire: lantern_hollow(),
          start: {1, hour: 12},
          terrain: @terrain,
          seed: seed
        )

      on_exit(fn -> Avwe.stop_world(cold) end)

      {:ok, view, _html} = live(conn, ~p"/play/hollow_cold/wren")

      assert eventually(fn -> is_list(scene_of(view)["rows"]) end, 10_000)
    end

    test "does not draw what is out of sight: Odo and the tower are 150 cells away", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      scene = scene_of(view)

      assert thing(scene, "odo") == nil
      assert thing(scene, "far-tower") == nil
    end
  end

  describe "a click on the map" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      %{view: view, scene: scene_of(view)}
    end

    defp click(view, [x, y]), do: render_hook(view, "cell", %{"x" => x, "y" => y})

    test "on a place goes there", %{view: view, scene: scene} do
      click(view, thing(scene, "mill-pond")["cell"])
      Avwe.step(@world, 3)
      heard(view, "wren")

      assert has_element?(view, "#log li.percept", "You set off toward Mill Pond.")
      assert has_element?(view, "#look p", "You are Wren, at Mill Pond.")
    end

    test "on somebody names them, and goes nowhere", %{view: view} do
      tamsin = neighbour("tamsin")
      {:ok, _ref} = Session.act(tamsin, :walk, params: %{direction: "north", distance_m: 200})
      Avwe.step(@world, 2)
      heard(view, "wren")
      moved = thing(scene_of(view), "tamsin")
      assert moved["cell"] != scene_of(view)["center"]

      click(view, moved["cell"])

      assert has_element?(view, "#log li.reply", "Tamsin is there.")
      refute has_element?(view, "#log li.percept", "You set off")
    end

    test "on the ground says what it is", %{view: view, scene: scene} do
      [x, y] = scene["center"]

      click(view, [x + 1, y + 1])

      assert has_element?(view, "#log li.reply", "You see clay there.")
    end

    test "beyond the circle of sight says it cannot be seen", %{view: view, scene: scene} do
      [x, y] = scene["center"]

      click(view, [x + 60, y])
      click(view, [x, y - 200])
      click(view, [-5, -5])

      assert view |> log() |> String.split("You can't see that far.") |> length() == 4
    end

    test "that is not a cell is ignored", %{view: view} do
      before = log(view)

      for params <- [%{"x" => "a", "y" => 1}, %{"x" => 1.5, "y" => 2}, %{"x" => 1}, %{}] do
        render_hook(view, "cell", params)
      end

      assert log(view) == before
      assert Process.alive?(view.pid)
    end

    test "is the player's presence too", %{conn: conn} do
      Application.put_env(:avwe, :play_idle_after_ms, 300)
      on_exit(fn -> Application.delete_env(:avwe, :play_idle_after_ms) end)

      neighbour("tamsin")
      {:ok, view, _html} = live(Phoenix.ConnTest.recycle(conn), ~p"/play/hollow_play/pell")
      scene = scene_of(view)

      for _n <- 1..5 do
        Process.sleep(100)
        click(view, thing(scene, "tamsin")["cell"])
      end

      Avwe.step(@world, 1)
      assert controller("pell") == :human
    end
  end

  describe "leaving" do
    test "frees the body when the page closes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      assert taken?("wren")

      GenServer.stop(view.pid)

      assert eventually(fn -> not taken?("wren") end)
    end

    test "frees the body, and goes to the lobby, at the Leave link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")

      {:ok, lobby, _html} =
        view |> element("a", "Leave") |> render_click() |> follow_redirect(conn)

      assert has_element?(lobby, "h1", "AVWE")
      assert eventually(fn -> not taken?("wren") end)
    end

    test "says so, with a way back, when the world stops, and takes no more commands",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      refute has_element?(view, ".notice")

      Avwe.stop_world(@world)

      assert eventually(fn -> has_element?(view, ".notice.error", "has ended") end)
      assert has_element?(view, ~s(.notice a[href="/"]), "Back to the lobby")
      refute has_element?(view, "form#command")

      render_click(view, "command", %{"line" => "look"})
      assert has_element?(view, "#log li.reply", "You are no longer in the world.")
    end
  end

  defp burning?(hearth) do
    {:ok, snapshot} = Avwe.snapshot(@world)
    snapshot.components.hearth[hearth].burning
  end
end
