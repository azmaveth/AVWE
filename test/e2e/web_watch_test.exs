defmodule Avwe.E2E.WebWatchTest do
  @moduledoc """
  End to end over a real socket: the watch page of the Ember Reach, an hour
  before the river's source fails, on a manual clock. The page is read over HTTP
  and its LiveView joined over a websocket by the protocol the page's script
  speaks, so what is checked is the transport, the cookie and the tokens as a
  browser uses them; the canvas it draws on is for the browser tests.
  """

  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures
  import Avwe.Test.WebPage, only: [frames_until: 2, push_event: 5]

  alias Avwe.Test.{HTTPClient, WebPage, WebSocketClient}

  @world :ember_watch_e2e
  @path "/watch/ember_watch_e2e"
  @mira "mira-vale"

  setup do
    {:ok, _pid} =
      Avwe.start_world(@world, ember_reach_opts(start: {812, day: 200, hour: 14}))

    on_exit(fn -> Avwe.stop_world(@world) end)

    # The ground is built once for a terrain, here, so that no test waits for it.
    {:ok, %{terrain: terrain}} = Avwe.snapshot(@world)
    Avwe.GroundCache.world(terrain)

    {:ok, {_ip, port}} = AvweWeb.Endpoint.server_info(:http)
    %{port: port}
  end

  defp sessions, do: DynamicSupervisor.count_children(Avwe.Sessions).active

  # Whether what the page was sent so far has `text` in it.
  defp sent?(frames, text), do: Enum.any?(frames, &(Jason.encode!(&1) =~ text))

  defp until_sent(socket, text), do: frames_until(socket, &sent?(&1, text))

  describe "the lobby and the plain request" do
    test "offers the world to watch, and a request for it is the page, joining", %{port: port} do
      lobby = HTTPClient.request(port, "GET", "/")
      assert lobby.status == 200
      assert lobby.body =~ ~s(href="#{@path}")
      assert lobby.body =~ "Watch The Ember Reach"

      before = sessions()
      page = HTTPClient.request(port, "GET", @path)

      assert page.status == 200
      assert page.body =~ "Joining The Ember Reach..."
      assert page.body =~ ~s(phx-hook="WorldCanvas")
      refute page.body =~ "data-scene"
      assert sessions() == before
    end

    test "sends a request for a world that is not running to the lobby", %{port: port} do
      response = HTTPClient.request(port, "GET", "/watch/nowhere")

      assert response.status == 302
      assert WebPage.header(response, "location") == ["/"]
    end
  end

  describe "a page's socket" do
    test "is given the valley when it joins, and then the ground, which it is sent once",
         %{port: port} do
      {socket, topic, reply, _cookie} = WebPage.open(port, @path)

      assert [
               "4",
               "4",
               ^topic,
               "phx_reply",
               %{"status" => "ok", "response" => %{"rendered" => rendered}}
             ] = reply

      joined = Jason.encode!(rendered)
      assert joined =~ "Watching"
      assert joined =~ "812 AR, day 200, 14:00"
      assert joined =~ "things"
      assert joined =~ "overlays"

      # The ground is made beside the page's joining, and comes in a message of
      # its own: its rows, and the bed cells of each reach.
      frames = until_sent(socket, "reaches")
      assert sent?(frames, "rows")
      assert sent?(frames, "legend")

      WebSocketClient.close(socket)
    end

    test "is sent what changes as the world steps: the clock, and what the log says",
         %{port: port} do
      {socket, _topic, _reply, _cookie} = WebPage.open(port, @path)
      until_sent(socket, "reaches")

      Avwe.step(@world, 1)
      assert socket |> until_sent("14:01") |> sent?("14:01")

      for _hour <- 1..4, do: Avwe.step(@world, 60)

      frames =
        frames_until(socket, fn frames ->
          sent?(frames, "falls silent near Willow Docks.")
        end)

      for line <- [
            "The spring stops welling up.",
            "The river falls silent near The Source.",
            "The river falls silent near The Dry Bend.",
            "The river falls silent near Ember Reach.",
            "The river falls silent near Willow Docks."
          ] do
        assert sent?(frames, line), line
      end

      WebSocketClient.close(socket)
    end

    test "answers a pick of the hook with what is at the cell", %{port: port} do
      {socket, topic, _reply, _cookie} = WebPage.open(port, @path)
      until_sent(socket, "reaches")

      {:ok, snapshot} = Avwe.snapshot(@world)
      {x, y} = snapshot.components.position[@mira]

      push_event(socket, topic, "5", "cell", %{"x" => x, "y" => y, "r" => 0})
      frames = until_sent(socket, "Mira Vale (person)")

      assert sent?(frames, "Mira Vale (person), on its routine;")

      push_event(socket, topic, "6", "cell", %{"x" => 0, "y" => 0, "r" => 0})
      assert socket |> until_sent("Nothing there.") |> sent?("Nothing there.")

      WebSocketClient.close(socket)
    end

    test "holds no body, and its session goes when the socket closes", %{port: port} do
      before = sessions()
      {socket, _topic, _reply, _cookie} = WebPage.open(port, @path)
      assert sessions() == before + 1

      {:ok, bodies} = Avwe.bodies(@world)
      assert Enum.all?(bodies, &(&1.taken == false))

      WebSocketClient.close(socket)
      assert eventually(fn -> sessions() == before end, 5_000)
    end

    test "is one of any number: a second page watches beside the first", %{port: port} do
      {one, _topic, _reply, _cookie} = WebPage.open(port, @path)
      {two, _topic, _reply, _cookie} = WebPage.open(port, @path)

      Avwe.step(@world, 1)

      assert one |> until_sent("14:01") |> sent?("14:01")
      assert two |> until_sent("14:01") |> sent?("14:01")

      WebSocketClient.close(one)
      WebSocketClient.close(two)
    end
  end
end
