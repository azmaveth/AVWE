defmodule Avwe.Session do
  @moduledoc """
  One controller's connection to a world.

  A session holds the lease on one body, or watches as a spectator. It turns
  the world's events into percepts for its controller and passes the
  controller's intents to the region. Every controller (telnet, MCP, Arbor)
  goes through a session, so none of them has a back door into world state.

  Percepts go to the session's sink as
  `{:avwe_percepts, session, [%Avwe.Percept{}]}`. The session stops, and the
  lease is released, when the sink exits.

  Start sessions with `Avwe.connect/2`.
  """

  use GenServer, restart: :temporary

  alias Avwe.{Intent, Perception, RegionServer}

  @region {0, 0}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "What the body senses right now and what it can do. See `Avwe.Perception.look/2`."
  @spec look(pid()) :: {:ok, map()} | {:error, term()}
  def look(session), do: GenServer.call(session, :look)

  @doc """
  Asks the body to do something. Returns the intent's ref; its result arrives
  later as a percept with `intent: ref`.

  Options: `:target`, `:params`, and `:ref` to choose the ref yourself.
  """
  @spec act(pid(), Intent.verb(), keyword()) :: {:ok, String.t()} | {:error, :spectator}
  def act(session, verb, opts \\ []), do: GenServer.call(session, {:act, verb, opts})

  @doc "The id of the session's body, or `nil` for a spectator."
  @spec body(pid()) :: String.t() | nil
  def body(session), do: GenServer.call(session, :body)

  @doc "Ends the session and releases its body."
  @spec close(pid()) :: :ok
  def close(session), do: GenServer.stop(session)

  @impl true
  def init(opts) do
    world = Keyword.fetch!(opts, :world)
    body = opts[:body]
    controller = Keyword.get(opts, :controller, :human)

    with {:ok, view} <- snapshot(world),
         :ok <- check_body(view, body),
         :ok <- claim(world, body, controller) do
      sink = Keyword.fetch!(opts, :sink)
      Process.monitor(sink)
      {:ok, _owner} = Avwe.subscribe(world)

      {:ok,
       %{
         world: world,
         body: body,
         controller: controller,
         sink: sink,
         next_ref: 1,
         next_percept: 1
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:look, _from, state) do
    reply =
      with {:ok, view} <- snapshot(state.world) do
        {:ok, Perception.look(view, state.body)}
      end

    {:reply, reply, state}
  end

  def handle_call(:body, _from, state), do: {:reply, state.body, state}

  def handle_call({:act, _verb, _opts}, _from, %{body: nil} = state) do
    {:reply, {:error, :spectator}, state}
  end

  def handle_call({:act, verb, opts}, _from, state) do
    ref = Keyword.get_lazy(opts, :ref, fn -> "i-#{state.next_ref}" end)

    intent =
      Intent.new(state.body, verb,
        ref: ref,
        target: opts[:target],
        params: Keyword.get(opts, :params, %{}),
        controller: state.controller
      )

    :ok = RegionServer.submit(state.world, @region, intent)
    {:reply, {:ok, ref}, %{state | next_ref: state.next_ref + 1}}
  end

  @impl true
  def handle_info({:avwe_events, world, events, view}, %{world: world} = state) do
    case Perception.percepts(view, state.body, events) do
      [] ->
        {:noreply, state}

      percepts ->
        numbered = Enum.with_index(percepts, state.next_percept)

        send(
          state.sink,
          {:avwe_percepts, self(), Enum.map(numbered, fn {p, n} -> %{p | id: "p-#{n}"} end)}
        )

        {:noreply, %{state | next_percept: state.next_percept + length(percepts)}}
    end
  end

  def handle_info({:DOWN, _ref, :process, sink, _reason}, %{sink: sink} = state) do
    {:stop, :normal, state}
  end

  defp snapshot(world) do
    case RegionServer.snapshot(world, @region) do
      {:ok, view} -> {:ok, view}
      {:error, :not_found} -> {:error, :no_such_world}
    end
  end

  defp check_body(_view, nil), do: :ok

  defp check_body(view, body) do
    if Map.has_key?(Map.get(view.components, :body, %{}), body),
      do: :ok,
      else: {:error, :no_such_body}
  end

  defp claim(_world, nil, _controller), do: :ok

  defp claim(world, body, controller) do
    case Registry.register(Avwe.Registry, {:lease, world, body}, controller) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _holder}} -> {:error, :body_taken}
    end
  end
end
