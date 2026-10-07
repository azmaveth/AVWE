defmodule AvweWeb.BrowserIdTest do
  use Avwe.Test.WebCase, async: false

  import Plug.Conn, only: [get_resp_header: 2, get_session: 2]

  alias AvweWeb.BrowserId

  defp call(session) do
    :get |> Plug.Test.conn("/") |> init_test_session(session) |> BrowserId.call([])
  end

  describe "the plug" do
    test "gives a session that has none a long random id" do
      id = get_session(call(%{}), "browser_id")

      assert is_binary(id)
      # Sixteen random bytes, as url-safe base64.
      assert byte_size(id) == 22
      assert id =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "gives each browser its own" do
      ids = for _browser <- 1..20, do: get_session(call(%{}), "browser_id")

      assert length(Enum.uniq(ids)) == 20
    end

    test "keeps the id a session already has" do
      assert get_session(call(%{"browser_id" => "kept"}), "browser_id") == "kept"
    end

    test "replaces what is not an id" do
      for bad <- ["", 5, nil, %{}] do
        id = get_session(call(%{"browser_id" => bad}), "browser_id")
        assert is_binary(id) and byte_size(id) == 22
      end
    end
  end

  describe "an id in a session, as a page is given it" do
    test "is read, when it is one" do
      assert BrowserId.from(%{"browser_id" => "abc", "_csrf_token" => "x"}) == "abc"
    end

    test "is nothing, when there is none or it is not one" do
      assert BrowserId.from(%{}) == nil
      assert BrowserId.from(%{"browser_id" => ""}) == nil
      assert BrowserId.from(%{"browser_id" => 5}) == nil
      assert BrowserId.from(%{"browser_id" => nil}) == nil
    end
  end

  describe "through the endpoint, as a browser asks for the lobby" do
    test "a new browser is given an id in a session cookie, which it keeps", %{conn: conn} do
      first = get(conn, ~p"/")
      id = get_session(first, "browser_id")
      assert is_binary(id)

      # The cookie is what carries it: not readable by a script, not sent along
      # with a request from another site, and gone when the browser is closed.
      assert [cookie] = get_resp_header(first, "set-cookie")
      assert cookie =~ "_avwe_key="
      assert cookie =~ "HttpOnly"
      assert cookie =~ "SameSite=Lax"
      refute String.downcase(cookie) =~ ~r/max-age|expires/

      # The same browser coming back is the same id; another browser is not.
      again = first |> recycle() |> Map.put(:host, "localhost") |> get(~p"/")
      assert get_session(again, "browser_id") == id

      other = get(conn, ~p"/")
      assert get_session(other, "browser_id") != id
    end

    # A page's own signed token carries the session to its socket, and that is
    # all: the id is not a thing the page shows.
    test "is never written into the page as text", %{conn: conn} do
      conn = get(conn, ~p"/")
      id = get_session(conn, "browser_id")

      refute html_response(conn, 200) =~ id
    end
  end
end
