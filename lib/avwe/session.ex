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

  ## Control

  The lease in the `Registry` is the runtime's exclusivity check; the body's
  `:control` component is the simulation's truth (`Avwe.Systems.Autopilot`
  reads it, and replay reproduces it). So right after claiming the lease the
  session submits a `:control` intent, and when it closes or its sink dies
  it submits `:release` (`terminate/2`). Both go through
  `Avwe.RegionServer.submit/3` like any other input, and are journaled. The
  results of those two intents are the session's own and never reach the
  controller as percepts.

  **Idle.** When no `act/3` has arrived for `:idle_after` real milliseconds
  (default ten minutes), the session submits `:release` and marks itself
  yielded, so the body goes back to its routine while the player reads. The
  next `act/3` submits `:control` first and then the act, in that order.
  Idleness is real time and lives here, never in the pure core.

  Start sessions with `Avwe.connect/2`.
  """

  use GenServer, restart: :temporary

  alias Avwe.{Intent, Perception, RegionServer}

  @region {0, 0}
  @idle_after 10 * 60 * 1_000

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

      state = %{
        world: world,
        body: body,
        controller: controller,
        sink: sink,
        terrain: view.terrain,
        next_ref: 1,
        next_percept: 1,
        idle_after: Keyword.get(opts, :idle_after, @idle_after),
        idle_tag: nil,
        yielded: false,
        lease_refs: MapSet.new()
      }

      {:ok, state |> take_control() |> arm_idle()}
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
    state = if state.yielded, do: take_control(%{state | yielded: false}), else: state
    ref = Keyword.get_lazy(opts, :ref, fn -> "i-#{state.next_ref}" end)

    intent =
      Intent.new(state.body, verb,
        ref: ref,
        target: opts[:target],
        params: Keyword.get(opts, :params, %{}),
        controller: state.controller
      )

    :ok = RegionServer.submit(state.world, @region, intent)
    {:reply, {:ok, ref}, arm_idle(%{state | next_ref: state.next_ref + 1})}
  end

  @impl true
  def handle_info({:avwe_events, world, events, view}, %{world: world} = state) do
    percepts = Perception.percepts(Map.put(view, :terrain, state.terrain), state.body, events)
    {own, percepts} = Enum.split_with(percepts, &MapSet.member?(state.lease_refs, &1.intent))

    state = %{
      state
      | lease_refs: Enum.reduce(own, state.lease_refs, &MapSet.delete(&2, &1.intent))
    }

    case percepts do
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

  def handle_info({:idle, tag}, %{idle_tag: tag} = state) do
    {:noreply, yield(state)}
  end

  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, sink, _reason}, %{sink: sink} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{body: body, yielded: false} = state) when body != nil do
    release(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Control

  defp take_control(%{body: nil} = state), do: state
  defp take_control(state), do: lease(state, :control)

  defp yield(%{body: nil} = state), do: state
  defp yield(state), do: %{release(state) | yielded: true, idle_tag: nil}

  defp release(state), do: lease(state, :release)

  # Submits one of the session's own lease intents, remembering its ref so
  # the result is kept from the controller. A world that is already gone is
  # no error here: there is nothing left to release.
  defp lease(state, verb) do
    ref = "#{verb}-#{System.unique_integer([:positive])}"
    intent = Intent.new(state.body, verb, ref: ref, controller: state.controller)

    try do
      RegionServer.submit(state.world, @region, intent)
    catch
      :exit, _gone -> {:error, :not_found}
    end

    %{state | lease_refs: MapSet.put(state.lease_refs, ref)}
  end

  defp arm_idle(%{body: nil} = state), do: state

  defp arm_idle(state) do
    tag = make_ref()
    Process.send_after(self(), {:idle, tag}, state.idle_after)
    %{state | idle_tag: tag}
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
