defmodule Avwe.Test.ReferenceAgent do
  @moduledoc """
  A scripted player with no language model, over the real MCP transport. It
  reads only what the protocol says: the structured results of the tools
  (`Avwe.Protocol`), as an agent framework would, and sorts everything it is
  told into what another body said, what it said itself, and the world's own
  narration, by the structure of each percept and never by what its text says.

  That sorting is what a client that labels other players' words as untrusted
  does, so a test that reads `told/1` reads what such a client would have
  labelled. The harness uses AVWE's own functions only to step the world and to
  know which player to wait for (`Avwe.Guests.offer/2`, `Avwe.Test.MCPClient`);
  the agent itself does not.
  """

  import ExUnit.Assertions
  import Avwe.Test.Fixtures, only: [eventually: 1]

  alias Avwe.Guests
  alias Avwe.Test.MCPClient

  defstruct [:client, :world, :id, told: []]

  @type t :: %__MODULE__{}
  @type told :: {:narration, String.t()} | {:said, map()} | {:heard, map()}

  @doc "A client of the server on `port`, playing in `world`, as nobody yet."
  @spec start(:inet.port_number(), atom()) :: t()
  def start(port, world) do
    client = MCPClient.connect(port)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        MCPClient.close(client)
      catch
        :exit, _gone -> :ok
      end
    end)

    %__MODULE__{client: client, world: world}
  end

  @doc """
  Arrives as a guest. The body is made at the world's next step, so the call
  is made in a task and the world stepped once its player is there.
  """
  @spec arrive(t(), String.t(), String.t() | nil) :: {t(), map()}
  def arrive(%__MODULE__{} = agent, name, backstory \\ nil) do
    {:ok, %{id: id}} = Guests.offer(name, backstory)
    args = %{"name" => name, "backstory" => backstory} |> Map.reject(fn {_k, v} -> is_nil(v) end)
    task = Task.async(fn -> MCPClient.call(agent.client, "arrive", args) end)
    assert eventually(fn -> MCPClient.mind(agent.world, id) != nil end)
    Avwe.step(agent.world, 1)
    result = Task.await(task)
    settled(agent, result, id)
  end

  @doc "An arrival that the server refused, as it told it."
  @spec arrive_refused(t(), map()) :: map()
  def arrive_refused(%__MODULE__{} = agent, args) do
    result = MCPClient.call(agent.client, "arrive", args)
    assert result.error?
    result
  end

  @doc "Takes a body that is free, by name or id."
  @spec join(t(), String.t()) :: {t(), map()}
  def join(%__MODULE__{} = agent, body) do
    result = MCPClient.call(agent.client, "join", %{"body" => body})
    settled(agent, result, result.data && result.data["body"])
  end

  @doc "A join that the server refused, as it told it."
  @spec join_refused(t(), String.t()) :: map()
  def join_refused(%__MODULE__{} = agent, body) do
    result = MCPClient.call(agent.client, "join", %{"body" => body})
    assert result.error?
    result
  end

  @doc "Lets the body go."
  @spec leave(t()) :: {t(), map()}
  def leave(%__MODULE__{} = agent) do
    result = MCPClient.call(agent.client, "leave")
    refute result.error?
    {%{agent | id: nil}, result}
  end

  @doc "One tool called at once, for those that do not wait on world time."
  @spec call(t(), String.t(), map()) :: {t(), map()}
  def call(%__MODULE__{} = agent, tool, args \\ %{}) do
    result = MCPClient.call(agent.client, tool, args)
    {observe(agent, result), result}
  end

  @doc """
  An `act` (a verb, or a plan of steps) that waits on world time, with the world
  stepped `:chunk` ticks at a time until it is answered, at most `:limit` times.
  """
  @spec act(t(), map(), keyword()) :: {t(), map()}
  def act(%__MODULE__{} = agent, args, opts \\ []) do
    chunk = Keyword.get(opts, :chunk, 1)
    limit = Keyword.get(opts, :limit, 3_000)
    task = MCPClient.calling(agent.client, agent.world, agent.id, "act", args)

    result =
      Enum.reduce_while(1..limit, nil, fn _n, nil ->
        MCPClient.step(agent.world, agent.id, chunk)

        case Task.yield(task, 100) do
          {:ok, result} -> {:halt, result}
          nil -> {:cont, nil}
        end
      end) || flunk("the call did not finish in #{limit} steps of #{chunk}")

    {observe(agent, result), result}
  end

  @doc "Says something, at a volume."
  @spec say(t(), String.t(), String.t()) :: {t(), map()}
  def say(%__MODULE__{} = agent, text, volume \\ "talk"),
    do: act(agent, %{"verb" => "say", "params" => %{"text" => text, "volume" => volume}})

  @doc "Writes a page in its notebook."
  @spec write(t(), String.t()) :: {t(), map()}
  def write(%__MODULE__{} = agent, text),
    do: act(agent, %{"verb" => "write", "params" => %{"text" => text}})

  @doc "Reads the last pages of its notebook, as the protocol gives them."
  @spec read(t(), pos_integer()) :: {t(), [map()]}
  def read(%__MODULE__{} = agent, last \\ 10) do
    {agent, result} = act(agent, %{"verb" => "read", "params" => %{"last" => last}})

    pages =
      for %{"data" => %{"pages" => pages}} <- result.data["percepts"], page <- pages, do: page

    {agent, pages}
  end

  @doc """
  Waits until the player's Mind has handled every percept of the steps so far
  (its session has handled the world's events once it answers a call, and the
  Mind the session's percepts once it answers one), so that a call that reads
  what was perceived finds it. The world is stepped by whoever acts; this is
  for a player that was only listening.
  """
  @spec settle(t()) :: t()
  def settle(%__MODULE__{world: world, id: id} = agent) do
    case MCPClient.mind(world, id) do
      nil ->
        agent

      mind ->
        %{session: session} = :sys.get_state(mind)
        _body = Avwe.Session.body(session)
        _state = :sys.get_state(mind)
        agent
    end
  end

  @doc """
  Where, in the percepts of a result as the protocol gave them, a string holds
  `marker`, as dotted paths (`"data.words.text"`, `"summary"`).
  """
  @spec where(map(), String.t()) :: [String.t()]
  def where(%{data: %{"percepts" => percepts}}, marker), do: paths(percepts, marker, [])

  defp paths(map, marker, path) when is_map(map),
    do: Enum.flat_map(map, fn {key, value} -> paths(value, marker, path ++ [key]) end)

  defp paths(list, marker, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, n} -> paths(value, marker, path ++ [n]) end)
  end

  defp paths(text, marker, path) when is_binary(text),
    do: if(String.contains?(text, marker), do: [path |> Enum.drop(1) |> Enum.join(".")], else: [])

  defp paths(_other, _marker, _path), do: []

  @doc """
  Writes down, in quotation, each thing it heard another body say that it has
  not written down, as a record of what was said and by whom: the one thing an
  agent that treats others' words as data does with them.
  """
  @spec remember_heard(t()) :: t()
  def remember_heard(%__MODULE__{told: told} = agent) do
    heard = for {:heard, words} <- told, do: words
    noted = for {:noted, words} <- told, do: words
    pending = heard -- noted

    Enum.reduce(pending, agent, fn words, agent ->
      {agent, _result} = write(agent, "Heard #{words["as"]} say: \"#{words["text"]}\"")
      %{agent | told: agent.told ++ [{:noted, words}]}
    end)
  end

  @doc "Everything it has been told, in order, sorted by structure."
  @spec told(t()) :: [told()]
  def told(%__MODULE__{told: told}), do: Enum.reject(told, &match?({:noted, _words}, &1))

  @doc "What others said that it heard, as `data.words`."
  @spec heard(t()) :: [map()]
  def heard(%__MODULE__{} = agent), do: for({:heard, words} <- told(agent), do: words)

  @doc """
  What a percept is, by its structure: words another body said, words it said
  itself, or the world's narration.
  """
  @spec classify(map()) :: told()
  def classify(%{"data" => %{"words" => %{"as" => "You"} = words}}), do: {:said, words}
  def classify(%{"data" => %{"words" => words}}), do: {:heard, words}
  def classify(percept), do: {:narration, percept["summary"]}

  # What was told, in a result, is kept.
  defp observe(agent, %{data: %{"percepts" => percepts}}) do
    %{agent | told: agent.told ++ Enum.map(percepts, &classify/1)}
  end

  defp observe(agent, _result), do: agent

  defp settled(agent, result, id) do
    refute result.error?, result.text
    {observe(%{agent | id: id}, result), result}
  end
end
