defmodule Avwe.Test.MCPClient do
  @moduledoc """
  An MCP player for end-to-end tests: ArborMCP's own client over real HTTP
  against an `Avwe.MCP` server on localhost.

  Tool calls that wait on world time block until the world is stepped, so
  tests start them with `calling/5` and step the world while they wait
  (`step_until_done/4`).
  """

  import ExUnit.Assertions

  alias Arbor.MCP.Client
  alias Avwe.MCP.Players
  alias Avwe.Test.Fixtures

  @timeout 40_000

  @doc """
  Connects to the server on `port`, at its endpoint `/mcp`.
  `protocol_mode` `:legacy_only` (the default) gives the client an MCP
  session; `:modern_only` speaks MCP 2026-07-28, which has none.
  """
  def connect(port, protocol_mode \\ :legacy_only) do
    {:ok, client} =
      Client.start_link(
        transport: :http,
        url: "http://127.0.0.1:#{port}/mcp",
        use_sse: false,
        protocol_mode: protocol_mode,
        request_timeout: @timeout
      )

    client
  end

  @doc """
  One raw HTTP request to the server on `port`, for what ArborMCP's client
  does not show: `%{status, headers, body}`, header names lowercased.
  Options: `:headers` and `:body` (encoded as JSON).
  """
  def http(port, method, path, opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    url = ~c"http://127.0.0.1:#{port}#{path}"

    headers =
      for {name, value} <- Keyword.get(opts, :headers, []), do: {~c"#{name}", ~c"#{value}"}

    request =
      case Keyword.fetch(opts, :body) do
        {:ok, body} -> {url, headers, ~c"application/json", Jason.encode!(body)}
        :error -> {url, headers}
      end

    {:ok, {{_version, status, _reason}, response_headers, body}} =
      :httpc.request(method, request, [timeout: @timeout], body_format: :binary)

    %{
      status: status,
      headers: Map.new(response_headers, fn {name, value} -> {"#{name}", "#{value}"} end),
      body: body
    }
  end

  @doc """
  The JSON-RPC message in a response body, whether plain JSON or a
  server-sent event stream.
  """
  def message(%{headers: headers, body: body}) do
    if String.contains?(headers["content-type"] || "", "text/event-stream") do
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", &(&1 |> String.trim_leading("data:") |> String.trim_leading()))
      |> Jason.decode!()
    else
      Jason.decode!(body)
    end
  end

  @doc "Ends the session (an HTTP DELETE) and stops the client."
  def close(client) do
    :ok = Client.disconnect(client)
    Client.stop(client)
  end

  @doc """
  Calls a tool and returns `%{text, data, error?}`: the text content, the
  structured content (with string keys, as JSON gives it) and whether it
  is a tool error.
  """
  def call(client, tool, args \\ %{}) do
    {:ok, result} =
      Client.call_tool(client, tool, args, timeout: @timeout, format: :map)

    %{
      text: result |> Map.get("content", []) |> Enum.map_join("\n", & &1["text"]),
      data: result["structuredContent"],
      error?: result["isError"] == true
    }
  end

  @doc "Starts a tool call in a task, and returns once the body's Mind is waiting on it."
  def calling(client, world, body, tool, args) do
    task = Task.async(fn -> call(client, tool, args) end)
    Fixtures.eventually(fn -> waiting?(world, body) end)
    task
  end

  @doc """
  Steps the world one tick at a time until `task` (from `calling/5`) has
  its answer, at most `max` ticks, and returns the answer.
  """
  def step_until_done(task, world, body, max \\ 120) do
    Enum.reduce_while(1..max, nil, fn _n, nil ->
      Avwe.step(world, 1)
      settle(world, body)

      case Task.yield(task, 50) do
        {:ok, result} -> {:halt, result}
        nil -> {:cont, nil}
      end
    end) || flunk("The call did not finish within #{max} ticks")
  end

  @doc """
  Steps the world `n` ticks, one at a time, letting the body's Mind handle
  each tick's percepts (and submit its plan's next step) before the next.
  """
  def step(world, body, n \\ 1) do
    for _n <- 1..n do
      Avwe.step(world, 1)
      settle(world, body)
    end

    :ok
  end

  @doc "The Mind playing `body` in `world`, or nil."
  def mind(world, body) do
    with key when key != nil <- Players.playing(world)[body],
         {:ok, mind, _world} <- Players.mind(key) do
      mind
    else
      _nobody -> nil
    end
  end

  # Waits until the body's Mind has handled every percept of the steps so
  # far: its session has handled the world's events once it answers a
  # call, and the Mind the session's percepts once it answers one.
  defp settle(world, body) do
    case mind(world, body) do
      nil ->
        :ok

      mind ->
        %{session: session} = :sys.get_state(mind)
        _body = Avwe.Session.body(session)
        _state = :sys.get_state(mind)
        :ok
    end
  end

  defp waiting?(world, body) do
    case mind(world, body) do
      nil -> false
      mind -> :sys.get_state(mind).waiter != nil
    end
  end
end
