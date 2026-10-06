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

  alias Avwe.Test.{HTTPClient, WebSocketClient}

  @world :hollow_web
  @assets Path.expand("../../priv/static/assets", __DIR__)
  @unserved Path.expand("../../priv/static", __DIR__)

  setup do
    {:ok, _pid} = Avwe.start_world(@world, quire: lantern_hollow(), start: {1, hour: 12})
    on_exit(fn -> Avwe.stop_world(@world) end)

    {:ok, {ip, port}} = AvweWeb.Endpoint.server_info(:http)
    %{ip: ip, port: port}
  end

  defp header(response, name) do
    for {^name, value} <- response.headers, do: value
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
    # with the tokens in it, over a socket from its own origin.
    defp open_page(port, path) do
      page = HTTPClient.request(port, "GET", path)
      assert page.status == 200

      [cookie] = for set <- header(page, "set-cookie"), do: set |> String.split(";") |> hd()
      [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, page.body)
      [_, id] = Regex.run(~r/<div[^>]* id="(phx-[^"]+)"[^>]*data-phx-main/s, page.body)
      [_, session] = Regex.run(~r/data-phx-session="([^"]+)"/, page.body)
      [_, static] = Regex.run(~r/data-phx-static="([^"]+)"/, page.body)

      {:ok, socket} =
        WebSocketClient.open(port, "/live/websocket?vsn=2.0.0&_csrf_token=#{csrf}", [
          {"origin", "http://127.0.0.1:#{port}"},
          {"cookie", cookie}
        ])

      join = %{
        "url" => "http://127.0.0.1:#{port}#{path}",
        "params" => %{"_csrf_token" => csrf, "_mounts" => 0},
        "session" => session,
        "static" => static
      }

      topic = "lv:" <> id
      WebSocketClient.push(socket, Jason.encode!(["4", "4", topic, "phx_join", join]))
      assert {:ok, reply} = WebSocketClient.recv(socket)
      {socket, topic, Jason.decode!(reply)}
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
  end
end
