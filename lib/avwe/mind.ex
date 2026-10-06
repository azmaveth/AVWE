defmodule Avwe.Mind do
  @moduledoc """
  The controller side of a body, for programs: the MCP adapter now, Arbor
  later. One per player.

  A Mind starts an `Avwe.Session` with itself as the sink, buffers the
  percepts the session sends, runs plans, and answers calls that wait on
  world time. It is runtime, not simulation: it may block callers and read
  the wall clock, and everything it does to the world goes through its
  session's intents, which the region journals as usual, so replay holds.
  Its plan lives only here: if the Mind dies the plan is gone, its session
  closes and the body goes back to its routine.

  ## Calls

    * `start/3` takes the body. `look/1` is the session's look; the first
      one carries `away`, what the body did while nobody held it, and later
      ones an empty `away`.
    * `act/3` runs one step or a plan and waits until the plan is done, a
      step fails, something worth attention is perceived, or `max_wait_ms`
      passes, whichever comes first (see `act/3`).
    * `stop/2` drops the plan and stops what the body is doing, and waits
      for that like `act/3`.
    * `percepts/1` returns and clears what was perceived since the last
      call, without acting.
    * `close/1` ends the Mind and gives the body back.

  A step is `{verb, opts}` (or `{verb}`), with the opts of
  `Avwe.Session.act/3`: `:target`, `:params` and, rarely, `:ref`. The verbs
  `:control` and `:release`, and refs starting with `auto-`, are refused
  with `{:error, :reserved}`, before anything is submitted.

  ## Replies

  `act/3`, `stop/2` and `percepts/1` reply `{:ok, report}`:

      %{
        status: :done | :failed | :interrupted | :still_going | :idle,
        percepts: [%Avwe.Percept{}],   # since the previous call returned, in order
        plan: [{verb, opts}],          # steps not yet submitted
        action: %{ref, verb, target} | nil,  # the step under way, or the body's own doing
        dropped: n                     # percepts lost to the buffer bound
      }

  `action` is the plan's step under way or, when there is none, the
  durative action an earlier step started that the body is still doing (a
  wait that an instant step, such as speaking, did not end). It is `nil`
  only when the body is doing nothing the Mind asked for.

  The buffer holds at most 500 percepts; when it overflows the oldest are
  dropped and counted in the next reply's `dropped`.

  Between calls the Mind keeps going: as each step succeeds it submits the
  next, so a plan runs while the program thinks, and a failed step drops
  the rest. Only one call waits at a time: a call made while another waits
  answers the waiting one first, as if its wait had run out. A caller that
  dies while it waits (a cancelled request) is forgotten, and what it would
  have been told waits for the next call.

  When the session yields the body to its routine (its idle rule: no call
  for `:idle_after`), the plan ends there, as `:failed`, and the Mind
  forgets what it was doing: the routine has the body now, and only the
  program's next act takes it back.

  With no call for `:quit_after` real milliseconds (default 30 minutes) the
  Mind stops and the body is released.
  """

  use GenServer, restart: :temporary

  alias Avwe.Session

  @controllers [:mcp, :arbor]
  @reserved_verbs [:control, :release]
  @buffer 500
  @quit_after 30 * 60 * 1_000
  @interrupt_at 0.6
  @max_wait_ms 25_000

  @type step :: {atom(), keyword()} | {atom()}
  @type report :: %{
          status: :done | :failed | :interrupted | :still_going | :idle,
          percepts: [Avwe.Percept.t()],
          plan: [{atom(), keyword()}],
          action: %{ref: String.t(), verb: atom(), target: String.t() | nil} | nil,
          dropped: non_neg_integer()
        }

  @doc """
  Starts a Mind playing `body` in `world`.

  Options: `:controller` (`:mcp`, the default, or `:arbor`), `:idle_after`
  (passed to the session: real ms without a call before the body is yielded
  to its routine until the next act) and `:quit_after` (real ms without a
  call before the Mind stops and releases the body; default 30 minutes).

  Fails as `Avwe.connect/2` does (`:no_such_world`, `:no_such_body`,
  `:body_taken`), or with `:invalid_controller`.
  """
  @spec start(atom(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(world, body, opts \\ []) do
    opts = opts |> Keyword.put(:world, world) |> Keyword.put(:body, body)
    DynamicSupervisor.start_child(Avwe.Minds, {__MODULE__, opts})
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  What the body senses right now and what it can do (`Avwe.Session.look/1`).
  Only the first look carries `away`, "While you were away"; later ones
  have `away: []`.
  """
  @spec look(pid()) :: {:ok, map()} | {:error, term()}
  def look(mind), do: GenServer.call(mind, :look)

  @doc """
  Runs one step or a plan (a list of steps) and waits.

  Submits the first step at once, dropping any plan the Mind was running,
  and replies when the first of these happens:

    * `:done` - the last step's result is a success.
    * `:failed` - a step's result is not a success; the rest of the plan is
      dropped.
    * `:interrupted` - a sensed percept at or above `:interrupt_at` arrives
      that is not about the plan's own doing (being spoken to, the river
      falling silent, a discovery). The action and the plan keep going.
    * `:still_going` - `:max_wait_ms` passes. The action and the plan keep
      going.

  Options: `:interrupt_at` (salience, default #{@interrupt_at}) and
  `:max_wait_ms` (real ms, default #{@max_wait_ms}). Fails with
  `{:error, :reserved}`, `{:error, :invalid_ref}`, `{:error,
  :invalid_plan}` (not a step, or an empty plan) or `{:error,
  :invalid_options}` without submitting anything.
  """
  @spec act(pid(), step() | [step()], keyword()) :: {:ok, report()} | {:error, term()}
  def act(mind, steps, opts \\ []) do
    timeout =
      case Keyword.get(opts, :max_wait_ms, @max_wait_ms) do
        max_wait when is_integer(max_wait) and max_wait >= 0 -> max_wait + 5_000
        _invalid -> 5_000
      end

    GenServer.call(mind, {:act, steps, opts}, timeout)
  end

  @doc """
  Drops the plan and stops what the body is doing; replies like `act/3`,
  once the stop's result is in (`:done`). Takes `act/3`'s options.
  """
  @spec stop(pid(), keyword()) :: {:ok, report()} | {:error, term()}
  def stop(mind, opts \\ []), do: act(mind, {:stop, []}, opts)

  @doc """
  Returns and clears what was perceived since the last call, without
  acting. `status` is `:still_going` while a plan runs, how the last plan
  ended (`:done` or `:failed`) if it ended since the previous call
  returned, and `:idle` otherwise.
  """
  @spec percepts(pid()) :: {:ok, report()}
  def percepts(mind), do: GenServer.call(mind, :percepts)

  @doc "The id of the Mind's body."
  @spec body(pid()) :: String.t()
  def body(mind), do: GenServer.call(mind, :body)

  @doc "Ends the Mind; its session closes and the body goes back to its routine."
  @spec close(pid()) :: :ok
  def close(mind), do: GenServer.stop(mind)

  @impl true
  def init(opts) do
    controller = Keyword.get(opts, :controller, :mcp)
    body = Keyword.fetch!(opts, :body)

    connect =
      [body: body, controller: controller, sink: self()] ++
        Keyword.take(opts, [:idle_after])

    with :ok <- check_controller(controller),
         {:ok, session} <- Avwe.connect(Keyword.fetch!(opts, :world), connect) do
      Process.monitor(session)

      state = %{
        session: session,
        body: body,
        looked: false,
        buffer: :queue.new(),
        buffered: 0,
        dropped: 0,
        plan: [],
        current: nil,
        doing: nil,
        ended: nil,
        waiter: nil,
        quit_after: Keyword.get(opts, :quit_after, @quit_after),
        quit_tag: nil
      }

      {:ok, arm_quit(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:look, _from, state) do
    reply =
      case Session.look(state.session) do
        {:ok, look} when state.looked -> {:ok, Map.put(look, :away, [])}
        other -> other
      end

    {:reply, reply, arm_quit(%{state | looked: true})}
  end

  def handle_call(:body, _from, state), do: {:reply, state.body, state}

  def handle_call(:percepts, _from, state) do
    state = answer_waiter(state)
    :ok = Session.touch(state.session)

    status =
      cond do
        state.current -> :still_going
        state.ended -> state.ended
        state.doing -> :still_going
        true -> :idle
      end

    {:reply, {:ok, report(state, status)}, state |> flush() |> arm_quit()}
  end

  def handle_call({:act, steps, opts}, from, state) do
    with {:ok, plan} <- plan(steps),
         {:ok, interrupt_at, max_wait} <- act_opts(opts) do
      state = %{answer_waiter(state) | plan: plan, current: nil, ended: nil}

      case submit_next(state) do
        {:ok, state} ->
          tag = make_ref()
          Process.send_after(self(), {:max_wait, tag}, max_wait)
          {caller, _tag} = from
          monitor = Process.monitor(caller)
          waiter = %{from: from, interrupt_at: interrupt_at, tag: tag, monitor: monitor}
          {:noreply, arm_quit(%{state | waiter: waiter})}

        {:error, reason, state} ->
          {:reply, {:error, reason}, arm_quit(state)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_quit(state)}
    end
  end

  @impl true
  def handle_info({:avwe_percepts, session, percepts}, %{session: session} = state) do
    {:noreply, Enum.reduce(percepts, state, &take/2)}
  end

  def handle_info({:max_wait, tag}, %{waiter: %{tag: tag}} = state),
    do: {:noreply, reply(state, :still_going)}

  def handle_info({:max_wait, _stale}, state), do: {:noreply, state}

  def handle_info({:quit, tag}, %{quit_tag: tag, waiter: nil} = state),
    do: {:stop, :normal, state}

  def handle_info({:quit, _stale_or_waiting}, state), do: {:noreply, state}

  # The waiting caller is gone (its request was cancelled or dropped): what
  # it would have been told stays buffered for the next call.
  def handle_info(
        {:DOWN, monitor, :process, _caller, _reason},
        %{waiter: %{monitor: monitor}} = state
      ),
      do: {:noreply, arm_quit(%{state | waiter: nil})}

  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state) do
    if state.waiter, do: GenServer.reply(state.waiter.from, {:error, :session_closed})
    {:stop, :normal, %{state | waiter: nil}}
  end

  # Percepts

  # Each percept is buffered, then may settle the plan's current step or
  # interrupt a waiting caller. A caller is answered at the first percept
  # that ends its wait; the rest of the batch waits for the next call.
  defp take(percept, state) do
    state = percept |> buffer(state) |> follow(percept)
    current = state.current

    cond do
      percept.type == :control_released ->
        yielded(state)

      current != nil and percept.kind == :result and percept.intent == current.ref ->
        settle(state, percept.outcome)

      state.waiter != nil and interrupts?(percept, state.waiter.interrupt_at) ->
        reply(state, :interrupted)

      true ->
        state
    end
  end

  defp settle(%{plan: []} = state, :success), do: finish(state, :done)

  defp settle(state, :success) do
    case submit_next(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> finish(state, :failed)
    end
  end

  defp settle(state, _not_success), do: finish(state, :failed)

  # Only what the body senses of the world can interrupt: not the plan's
  # results or progress, and not the body's own doings that it senses (its
  # fires carry an issuer).
  defp interrupts?(percept, interrupt_at) do
    percept.kind == :sensed and percept.issuer == nil and percept.salience >= interrupt_at
  end

  # What the body is doing for the Mind: a step's durative action from its
  # start until its result, which may outlive the plan that asked for it.
  defp follow(%{current: %{ref: ref} = current} = state, %{type: :action_started, intent: ref}),
    do: %{state | doing: current}

  defp follow(%{doing: %{ref: ref}} = state, %{kind: :result, intent: ref}),
    do: %{state | doing: nil}

  defp follow(state, _percept), do: state

  # The session yielded the body to its routine: the plan ends, and the
  # routine, not the Mind, decides what the body does until the next act.
  defp yielded(%{current: nil} = state), do: %{state | plan: [], doing: nil}
  defp yielded(state), do: finish(%{state | doing: nil}, :failed)

  defp buffer(percept, state), do: buffer_percept(state, percept)

  defp buffer_percept(%{buffered: @buffer} = state, percept) do
    {_oldest, queue} = :queue.out(state.buffer)
    %{state | buffer: :queue.in(percept, queue), dropped: state.dropped + 1}
  end

  defp buffer_percept(state, percept),
    do: %{state | buffer: :queue.in(percept, state.buffer), buffered: state.buffered + 1}

  defp flush(state), do: %{state | buffer: :queue.new(), buffered: 0, dropped: 0, ended: nil}

  # The plan

  defp submit_next(%{plan: [{verb, opts} | rest]} = state) do
    case Session.act(state.session, verb, opts) do
      {:ok, ref} ->
        {:ok, %{state | plan: rest, current: %{ref: ref, verb: verb, target: opts[:target]}}}

      {:error, reason} ->
        {:error, reason, %{state | plan: [], current: nil}}
    end
  end

  defp finish(state, status) do
    state = %{state | plan: [], current: nil}
    if state.waiter, do: reply(state, status), else: %{state | ended: status}
  end

  defp reply(%{waiter: waiter} = state, status) do
    Process.demonitor(waiter.monitor, [:flush])
    GenServer.reply(waiter.from, {:ok, report(state, status)})
    %{flush(state) | waiter: nil} |> arm_quit()
  end

  defp answer_waiter(%{waiter: nil} = state), do: state
  defp answer_waiter(state), do: reply(state, :still_going)

  defp report(state, status) do
    %{
      status: status,
      percepts: :queue.to_list(state.buffer),
      plan: state.plan,
      action: state.current || state.doing,
      dropped: state.dropped
    }
  end

  defp plan({_verb, _opts} = step), do: plan([step])
  defp plan({_verb} = step), do: plan([step])
  defp plan([_step | _rest] = steps), do: steps |> Enum.map(&step/1) |> all_steps()
  defp plan(_other), do: {:error, :invalid_plan}

  defp step({verb}), do: step({verb, []})

  defp step({verb, opts}) when is_atom(verb) and is_list(opts) do
    ref = opts[:ref]

    cond do
      not Keyword.keyword?(opts) -> {:error, :invalid_plan}
      verb in @reserved_verbs -> {:error, :reserved}
      ref != nil and not is_binary(ref) -> {:error, :invalid_ref}
      is_binary(ref) and String.starts_with?(ref, "auto-") -> {:error, :reserved}
      true -> {:ok, {verb, Keyword.take(opts, [:target, :params, :ref])}}
    end
  end

  defp step(_other), do: {:error, :invalid_plan}

  defp all_steps(checked) do
    case Enum.find(checked, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(checked, fn {:ok, step} -> step end)}
      error -> error
    end
  end

  defp act_opts(opts) do
    interrupt_at = Keyword.get(opts, :interrupt_at, @interrupt_at)
    max_wait = Keyword.get(opts, :max_wait_ms, @max_wait_ms)

    if is_number(interrupt_at) and is_integer(max_wait) and max_wait >= 0,
      do: {:ok, interrupt_at, max_wait},
      else: {:error, :invalid_options}
  end

  defp check_controller(controller) when controller in @controllers, do: :ok
  defp check_controller(_controller), do: {:error, :invalid_controller}

  defp arm_quit(state) do
    tag = make_ref()
    Process.send_after(self(), {:quit, tag}, state.quit_after)
    %{state | quit_tag: tag}
  end
end
