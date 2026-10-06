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
  controller as percepts; `act/3` refuses the two verbs, and the `auto-`
  refs that mark autopilot's intents, with `{:error, :reserved}`.

  **Idle.** When the controller has made no call, none of `act/3`,
  `look/1` and `touch/1`, for `:idle_after` real milliseconds (default ten
  minutes), the session submits `:release` and marks itself yielded, so
  the body goes back to its routine while the player reads. Every call
  re-arms the timer: a look, or a touch, which does nothing else, keeps
  the body in hand for that long again, and the next `act/3` takes it
  back, submitting `:control` first and then the act, in that order.
  Idleness is real time and lives here, never in the pure core. The
  controller sees
  the hand-over: a `:control_released` percept when the session yields
  ("You let your routine carry you.") and a `:control_taken` one when it
  takes the body back ("You take yourself in hand."); the take on
  connecting and the release on closing say nothing. While yielded, the
  routine's own actions reach the controller as percepts whose `issuer` is
  `:autopilot`, except its waits, which `Avwe.Perception` keeps quiet
  unless the controller stops one.

  **While you were away.** A body's look carries `away`, what it perceived
  while nobody held it (`Avwe.Perception.away/2`), which is empty once a
  controller holds it. The session takes the body only at the next step,
  and a live clock may step before the controller's first look, so the
  session reads `away` from the world as it found it on connecting, before
  it submitted `:control`, and its first `look/1` returns that. Later looks
  show the world's own: empty while held, what the routine did since the
  session yielded while yielded.

  Start sessions with `Avwe.connect/2`.
  """

  use GenServer, restart: :temporary

  alias Avwe.{Intent, Perception, RegionServer}

  @region {0, 0}
  @idle_after 10 * 60 * 1_000
  @controllers [:human, :mcp, :arbor]
  @reserved_verbs [:control, :release]
  @reserved_ref "auto-"
  @announced %{control_released: :yield, control_taken: :retake}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "What the body senses right now and what it can do. See `Avwe.Perception.look/2`."
  @spec look(pid()) :: {:ok, map()} | {:error, term()}
  def look(session), do: GenServer.call(session, :look)

  @doc """
  Asks the body to do something. Returns the intent's ref; its result arrives
  later as a percept with `intent: ref`.

  Options: `:target`, `:params`, and `:ref` to choose the ref yourself (a
  string; anything else is refused with `{:error, :invalid_ref}`). The
  verbs `:control` and `:release` are the session's own, and refs starting
  with `auto-` are autopilot's: both are refused with `{:error, :reserved}`.
  """
  @spec act(pid(), Intent.verb(), keyword()) ::
          {:ok, String.t()} | {:error, :spectator | :reserved | :invalid_ref}
  def act(session, verb, opts \\ []), do: GenServer.call(session, {:act, verb, opts})

  @doc """
  Marks the controller present: re-arms the idle timer, and nothing else.
  For the calls a client makes that neither act nor look, such as asking
  the time.
  """
  @spec touch(pid()) :: :ok
  def touch(session), do: GenServer.call(session, :touch)

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

    with :ok <- check_controller(controller),
         {:ok, view} <- snapshot(world),
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
        lease_refs: %{},
        away: body && Perception.away(view, body)
      }

      {:ok, state |> take_control(:take) |> arm_idle()}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:look, _from, state) do
    reply =
      with {:ok, view} <- snapshot(state.world) do
        {:ok, view |> Perception.look(state.body) |> arrival(state.away)}
      end

    {:reply, reply, arm_idle(%{state | away: nil})}
  end

  def handle_call(:touch, _from, state), do: {:reply, :ok, arm_idle(state)}

  def handle_call(:body, _from, state), do: {:reply, state.body, state}

  def handle_call({:act, _verb, _opts}, _from, %{body: nil} = state) do
    {:reply, {:error, :spectator}, state}
  end

  def handle_call({:act, verb, _opts}, _from, state) when verb in @reserved_verbs do
    {:reply, {:error, :reserved}, state}
  end

  def handle_call({:act, verb, opts}, _from, state) do
    ref = Keyword.get_lazy(opts, :ref, fn -> "i-#{state.next_ref}" end)

    cond do
      not is_binary(ref) ->
        {:reply, {:error, :invalid_ref}, state}

      String.starts_with?(ref, @reserved_ref) ->
        {:reply, {:error, :reserved}, state}

      true ->
        state =
          if state.yielded, do: take_control(%{state | yielded: false}, :retake), else: state

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
  end

  @impl true
  def handle_info({:avwe_events, world, events, view}, %{world: world} = state) do
    percepts = Perception.percepts(Map.put(view, :terrain, state.terrain), state.body, events)
    {own, percepts} = Enum.split_with(percepts, &Map.has_key?(state.lease_refs, &1.intent))
    settled = Enum.map(own, &Map.fetch!(state.lease_refs, &1.intent))
    percepts = Enum.filter(percepts, &announced?(&1, settled))
    state = %{state | lease_refs: Map.drop(state.lease_refs, Enum.map(own, & &1.intent))}

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
    release(state, :close)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # The first look tells what happened before the session took the body.
  defp arrival(look, nil), do: look
  defp arrival(look, away), do: %{look | away: away}

  # Control

  defp take_control(%{body: nil} = state, _why), do: state
  defp take_control(state, why), do: lease(state, :control, why)

  defp yield(%{body: nil} = state), do: state
  defp yield(state), do: %{release(state, :yield) | yielded: true, idle_tag: nil}

  defp release(state, why), do: lease(state, :release, why)

  # Submits one of the session's own lease intents, remembering its ref and
  # why it was sent (`:take`, `:yield`, `:retake` or `:close`), so the result
  # is kept from the controller and the hand-over it marks can be told from
  # the take on connecting. A world that is already gone is no error here:
  # there is nothing left to release.
  defp lease(state, verb, why) do
    ref = "#{verb}-#{System.unique_integer([:positive])}"
    intent = Intent.new(state.body, verb, ref: ref, controller: state.controller)

    try do
      RegionServer.submit(state.world, @region, intent)
    catch
      :exit, _gone -> {:error, :not_found}
    end

    %{state | lease_refs: Map.put(state.lease_refs, ref, why)}
  end

  # The hand-over percepts come from the body's own `:control_*` events,
  # which the session's lease intents raise: only the yield's release and
  # the retake's control are announced, and both are settled in the same
  # batch of events as the percept they explain.
  defp announced?(%{type: type} = _percept, settled) when is_map_key(@announced, type),
    do: @announced[type] in settled

  defp announced?(_percept, _settled), do: true

  # A yielded session has nothing to time: the next act takes the body back
  # and arms it again.
  defp arm_idle(%{body: nil} = state), do: state
  defp arm_idle(%{yielded: true} = state), do: state

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

  defp check_controller(controller) when controller in @controllers, do: :ok
  defp check_controller(_controller), do: {:error, :invalid_controller}

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
