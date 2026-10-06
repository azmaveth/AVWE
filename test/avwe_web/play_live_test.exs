defmodule AvweWeb.PlayLiveTest do
  use Avwe.Test.WebCase, async: false

  alias Avwe.Session

  @world :hollow_play

  setup do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)
  end

  defp taken?(body) do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == body)).taken
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

  describe "taking a body" do
    test "takes it when the page connects, and says who and where its body is", %{conn: conn} do
      refute taken?("wren")

      {:ok, view, html} = live(conn, ~p"/play/hollow_play/wren")

      assert taken?("wren")
      assert html =~ "Wren"
      assert has_element?(view, ".where", "Lantern Hollow")
      assert has_element?(view, ".arrival p", "You are Wren, at Hollow Green.")
      assert has_element?(view, ".arrival p", "Tamsin is here.")
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

  describe "while the page is open" do
    test "shows what happens as lines", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")

      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: "Good morning", volume: :talk})
      Avwe.step(@world, 1)
      heard(view, "wren")

      assert has_element?(view, ".log li", ~s(Tamsin says, "Good morning"))
    end

    test "shows what is said as text, never as markup", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      tamsin = neighbour("tamsin")
      words = ~s|<script>alert(1)</script> <b onclick="x()">hi</b>|

      {:ok, _ref} = Session.act(tamsin, :say, params: %{text: words, volume: :talk})
      Avwe.step(@world, 1)
      html = heard(view, "wren")

      assert has_element?(view, ".log li", words)
      refute has_element?(view, ".log script")
      refute has_element?(view, ".log b")
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
      lines = view |> element(".log") |> render() |> String.split("<li") |> length()

      assert lines - 1 == 200
      assert has_element?(view, ".log li", ~s(Tamsin says, "word 210"))
      refute has_element?(view, ".log li", ~s("word 10"))
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

    test "says so, with a way back, when the world stops", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/play/hollow_play/wren")
      refute has_element?(view, ".notice")

      Avwe.stop_world(@world)

      assert eventually(fn -> has_element?(view, ".notice.error", "has ended") end)
      assert has_element?(view, ~s(.notice a[href="/"]), "Back to the lobby")
    end
  end
end
