defmodule Avwe.Test.WebPage do
  @moduledoc """
  A page as a browser opens it, for end-to-end tests of the web client: its
  cookie kept, and its LiveView joined over a socket from its own origin with
  the tokens in the page, as the page's script does.
  """

  import ExUnit.Assertions

  alias Avwe.Test.{HTTPClient, WebSocketClient}

  @doc "The values of a response's header, by its lower-cased name."
  @spec header(HTTPClient.response(), String.t()) :: [String.t()]
  def header(response, name), do: for({^name, value} <- response.headers, do: value)

  @doc """
  Asks for `path`, and joins the LiveView in the page. A browser that has been
  here before sends the `cookie` it has (a page of the same browser), and keeps
  the one it is given; one that has not is a browser of its own.

  Returns the socket, the LiveView's topic, its reply to the join (decoded) and
  the cookie.
  """
  @spec open(:inet.port_number(), String.t(), String.t() | nil) ::
          {:gen_tcp.socket(), String.t(), list(), String.t() | nil}
  def open(port, path, cookie \\ nil) do
    sent = if cookie, do: [{"cookie", cookie}], else: []
    page = HTTPClient.request(port, "GET", path, sent)
    assert page.status == 200

    cookie =
      case for(set <- header(page, "set-cookie"), do: set |> String.split(";") |> hd()) do
        [given] -> given
        [] -> cookie
      end

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
    {socket, topic, Jason.decode!(reply), cookie}
  end

  @doc "Sends an event of a hook (`pushEvent` in the page's script) to the LiveView."
  @spec push_event(:gen_tcp.socket(), String.t(), String.t(), String.t(), map()) :: :ok
  def push_event(socket, topic, ref, event, value) do
    message = %{"type" => "hook", "event" => event, "value" => value}
    WebSocketClient.push(socket, Jason.encode!(["4", ref, topic, "event", message]))
  end

  @doc """
  The frames the LiveView sends in `timeout` ms, decoded and in order, until one
  satisfies `done` (which sees the frames so far, newest last).
  """
  @spec frames_until(:gen_tcp.socket(), ([list()] -> boolean()), timeout()) :: [list()]
  def frames_until(socket, done, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(socket, done, deadline, [])
  end

  defp collect(socket, done, deadline, frames) do
    left = deadline - System.monotonic_time(:millisecond)

    with true <- left > 0,
         {:ok, frame} <- WebSocketClient.recv(socket, left) do
      frames = frames ++ [Jason.decode!(frame)]
      if done.(frames), do: frames, else: collect(socket, done, deadline, frames)
    else
      _timed_out_or_closed -> frames
    end
  end
end
