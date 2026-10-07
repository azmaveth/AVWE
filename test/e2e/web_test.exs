defmodule Avwe.E2E.WebTest do
  @moduledoc """
  End to end over a real socket: the web client's endpoint on Bandit, spoken to
  as a browser speaks to it, and as a page that is not ours would. Lantern
  Hollow at noon on a manual clock. The pages are read over HTTP, and their
  LiveViews are joined over a websocket by the protocol the page's script
  speaks, so what is checked is the transport, the cookie and the tokens as a
  browser uses them (the browser itself comes with the Browser job).
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import ExUnit.CaptureLog

  import Avwe.Test.WebPage, only: [header: 2]

  alias Avwe.Test.{HTTPClient, WebPage, WebSocketClient}

  @world :hollow_web
  @assets Path.expand("../../priv/static/assets", __DIR__)
  @unserved Path.expand("../../priv/static", __DIR__)

  setup do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, {ip, port}} = AvweWeb.Endpoint.server_info(:http)
    %{ip: ip, port: port}
  end

  defp taken?(body) do
    {:ok, bodies} = Avwe.bodies(@world)
    Enum.find(bodies, &(&1.id == body)).taken
  end

  describe "the endpoint" do
    test "listens on loopback only", %{ip: ip} do
      assert ip == {127, 0, 0, 1}
    end

    test "serves the lobby, with its headers", %{port: port} do
      response = HTTPClient.request(port, "GET", "/")

      assert response.status == 200
      assert header(response, "content-type") == ["text/html; charset=utf-8"]
      assert [policy] = header(response, "content-security-policy")
      assert policy =~ "script-src 'self';"
      assert header(response, "x-content-type-options") == ["nosniff"]
      assert response.body =~ "Lantern Hollow"
      assert response.body =~ ~s(href="/play/hollow_web/wren")
    end

    test "serves what is built under assets, and nothing else of priv/static", %{port: port} do
      File.mkdir_p!(@assets)
      built = Path.join(@assets, "served-by-the-e2e-test.txt")
      other = Path.join(@unserved, "not-served-by-the-e2e-test.txt")
      File.write!(built, "built")
      File.write!(other, "private")
      on_exit(fn -> File.rm(built) && File.rm(other) end)

      assert %{status: 200, body: "built"} =
               HTTPClient.request(port, "GET", "/assets/served-by-the-e2e-test.txt")

      assert %{status: 404} = HTTPClient.request(port, "GET", "/not-served-by-the-e2e-test.txt")
    end

    test "answers to no name but its own, a built file no more than a page", %{port: port} do
      File.mkdir_p!(@assets)
      built = Path.join(@assets, "refused-by-the-e2e-test.txt")
      File.write!(built, "built")
      on_exit(fn -> File.rm(built) end)

      for path <- ["/", "/play/hollow_web/wren", "/assets/refused-by-the-e2e-test.txt"],
          host <- ["evil.example", "evil.example:#{port}", "localhost.evil.example"] do
        response = HTTPClient.request(port, "GET", path, [{"host", host}])

        assert response.status == 403, "#{host}#{path}"
        assert response.body == "This server answers only to its own name."
      end

      for host <- ["localhost:#{port}", "127.0.0.1:#{port}"] do
        assert %{status: 200} = HTTPClient.request(port, "GET", "/", [{"host", host}])
      end
    end

    test "has no long polling to fall back to", %{port: port} do
      assert %{status: 404} = HTTPClient.request(port, "GET", "/live/longpoll?vsn=2.0.0")
    end
  end

  describe "a page's socket" do
    test "opens from the origin its page came from, under the name it was reached by",
         %{port: port} do
      for name <- ["127.0.0.1", "localhost"] do
        assert {:ok, socket} =
                 WebSocketClient.open(port, "/live/websocket?vsn=2.0.0", [
                   {"host", "#{name}:#{port}"},
                   {"origin", "http://#{name}:#{port}"}
                 ])

        WebSocketClient.close(socket)
      end
    end

    test "does not open from another site, another service on this machine, or another scheme",
         %{port: port} do
      origins = [
        "http://evil.example:#{port}",
        "http://127.0.0.1:#{port + 1}",
        "http://localhost:3000",
        "https://127.0.0.1:#{port}",
        # The page's name must be the socket's.
        "http://localhost:#{port}"
      ]

      log =
        capture_log(fn ->
          for origin <- origins do
            assert {:error, 403} ==
                     WebSocketClient.open(port, "/live/websocket?vsn=2.0.0", [
                       {"host", "127.0.0.1:#{port}"},
                       {"origin", origin}
                     ]),
                   origin
          end
        end)

      # Each was turned away by the origin check itself.
      for origin <- origins, do: assert(log =~ "Origin of the request: #{origin}")
    end

    test "joins nothing without the token of a page this server rendered, whoever it claims to be",
         %{port: port} do
      # A page at another name that resolves to 127.0.0.1 sends that name as its
      # Host and its Origin, so the socket opens. But it cannot read a page (the
      # Host is refused), so it has no token to join with.
      {:ok, socket} =
        WebSocketClient.open(port, "/live/websocket?vsn=2.0.0", [
          {"host", "evil.example:#{port}"},
          {"origin", "http://evil.example:#{port}"}
        ])

      join = [
        "1",
        "1",
        "lv:phx-forged",
        "phx_join",
        %{
          "url" => "http://evil.example/",
          "session" => "forged",
          "static" => nil,
          "params" => %{}
        }
      ]

      WebSocketClient.push(socket, Jason.encode!(join))

      assert {:ok, reply} = WebSocketClient.recv(socket)

      assert ["1", "1", "lv:phx-forged", "phx_reply", %{"status" => "error"}] =
               Jason.decode!(reply)

      refute taken?("wren")
      WebSocketClient.close(socket)
    end
  end

  describe "a page's LiveView" do
    # What a browser does with a page: keep its cookie, and join the LiveView
    # with the tokens in it, over a socket from its own origin. A browser that
    # has been here before sends the cookie it has (a page of the same browser),
    # and keeps the one it is given; one that has not is a browser of its own.
    defp open_page(port, path) do
      {socket, topic, reply, _cookie} = open_page(port, path, nil)
      {socket, topic, reply}
    end

    defp open_page(port, path, cookie), do: WebPage.open(port, path, cookie)

    # What the page was told to do, once the server says to go elsewhere.
    defp redirect_of(socket, frames \\ 10) do
      case WebSocketClient.recv(socket, 5_000) do
        {:ok, frame} ->
          case Jason.decode!(frame) do
            [_join_ref, _ref, _topic, "live_redirect", redirect] -> redirect
            _other when frames > 1 -> redirect_of(socket, frames - 1)
            other -> flunk("no redirect, but #{inspect(other)}")
          end

        :closed ->
          flunk("the socket closed without a word of where to go")
      end
    end

    defp lease do
      Registry.lookup(Avwe.Registry, {:lease, @world, "wren"})
    end

    defp waiting(ms) do
      Application.put_env(:avwe, :play_retry_ms, ms)
      on_exit(fn -> Application.put_env(:avwe, :play_retry_ms, 0) end)
    end

    test "joins the lobby, which has the world in it", %{port: port} do
      {socket, topic, reply} = open_page(port, "/")

      assert [
               "4",
               "4",
               ^topic,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => rendered}}
             ] = reply

      assert Jason.encode!(rendered) =~ "Lantern Hollow"
      WebSocketClient.close(socket)
    end

    test "takes a body when the page's socket joins, and frees it when the socket closes",
         %{port: port} do
      refute taken?("wren")

      {socket, topic, reply} = open_page(port, "/play/hollow_web/wren")

      assert [
               "4",
               "4",
               ^topic,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => rendered}}
             ] = reply

      assert Jason.encode!(rendered) =~ "You are Wren, at Hollow Green."
      assert taken?("wren")

      WebSocketClient.close(socket)

      assert eventually(fn -> not taken?("wren") end)
    end

    test "turns away a second page for a body that is held, at its socket", %{port: port} do
      {first, _topic, _reply} = open_page(port, "/play/hollow_web/wren")

      # The plain request is answered with the page, whoever holds the body.
      plain = HTTPClient.request(port, "GET", "/play/hollow_web/wren")
      assert plain.status == 200
      assert plain.body =~ "Joining Lantern Hollow..."

      {second, _topic, reply} = open_page(port, "/play/hollow_web/wren")

      assert [_, _, _, "phx_reply", %{"status" => "error", "response" => response}] = reply
      assert response["live_redirect"]["to"] == "/"
      WebSocketClient.close(second)

      WebSocketClient.close(first)
      assert eventually(fn -> not taken?("wren") end)

      {third, _topic, reply} = open_page(port, "/play/hollow_web/wren")
      assert [_, _, _, "phx_reply", %{"status" => "ok"}] = reply
      WebSocketClient.close(third)
    end

    test "gives a body to a new page of the same browser while its old page is silent",
         %{port: port} do
      waiting(1_500)
      {old, _topic, _reply, cookie} = open_page(port, "/play/hollow_web/wren", nil)
      [{first, _lease}] = lease()

      # The old page says nothing from here on, and its socket is not closed: it
      # is a page whose connection dropped without a word, which the server
      # does not know of for a minute. The new page is of the same browser.
      {new, topic, reply, _cookie} = open_page(port, "/play/hollow_web/wren", cookie)

      assert [
               "4",
               "4",
               ^topic,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => rendered}}
             ] = reply

      assert Jason.encode!(rendered) =~ "You are Wren, at Hollow Green."
      assert [{second, _lease}] = lease()
      refute second == first

      # The old page is told, if it is there to hear, to go to the lobby.
      assert %{"to" => "/"} = redirect_of(old)

      WebSocketClient.close(new)
      WebSocketClient.close(old)
      assert eventually(fn -> not taken?("wren") end)
    end

    test "turns away a page of another browser, and the old page keeps its body",
         %{port: port} do
      waiting(300)
      {old, _topic, _reply, _cookie} = open_page(port, "/play/hollow_web/wren", nil)
      [{first, _lease}] = lease()

      # No cookie: a browser of its own, which is nobody the old page belongs to.
      {other, _topic, reply, _cookie} = open_page(port, "/play/hollow_web/wren", nil)

      assert [_, _, _, "phx_reply", %{"status" => "error", "response" => response}] = reply
      assert response["live_redirect"]["to"] == "/"
      WebSocketClient.close(other)

      assert [{^first, _lease}] = lease()
      assert {:error, :timeout} = :gen_tcp.recv(old, 0, 200)

      WebSocketClient.close(old)
      assert eventually(fn -> not taken?("wren") end)
    end

    test "offers a browser its own body in the lobby, and shows it as taken to another",
         %{port: port} do
      {page, _topic, _reply, cookie} = open_page(port, "/play/hollow_web/wren", nil)

      {mine, _topic, reply, _cookie} = open_page(port, "/", cookie)

      assert [_, _, _, "phx_reply", %{"status" => "ok", "response" => %{"rendered" => mine_now}}] =
               reply

      assert Jason.encode!(mine_now) =~ "open on another page of this browser"
      refute Jason.encode!(mine_now) =~ "(being played)"

      {others, _topic, reply, _cookie} = open_page(port, "/", nil)

      assert [
               _,
               _,
               _,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => others_now}}
             ] = reply

      assert Jason.encode!(others_now) =~ "(being played)"
      refute Jason.encode!(others_now) =~ "open on another page of this browser"

      for socket <- [mine, others, page], do: WebSocketClient.close(socket)
      assert eventually(fn -> not taken?("wren") end)
    end
  end
end
