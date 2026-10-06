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
  `Avwe.Session.act/3`, `:target` and `:params`, and two of the Mind's own:

    * `:target_name` - the target by name, such as `"the kiln-house
      hearth"`. A `:target` that is not the id of anything the body can
      name is taken as a name too. Names are resolved when the Mind submits
      the step, against a fresh look (the places the body knows for `:go`;
      the hearths in reach, then the fires in sight, for `:kindle` and
      `:douse`; the notebooks it carries for `:write` and `:read`), so a
      plan can name a hearth it will only reach on the way, and a fire
      seen far off is refused as too far rather than unknown. A name that
      matches nothing is passed to the world as given, and the world
      refuses it in its own words. A name that matches more than one thing
      is not submitted: the step fails with `{:ambiguous, query, names}`
      (see `problem` under Replies).
    * `:ref` - a label of the caller's own, kept on the step's `action` in
      reports. The Mind chooses every intent's ref itself (`"m-"` and 72
      random bits), so a result is only ever its own step's: not a ref an
      earlier session of the body used, in this run of the server or an
      earlier one whose actions the world still carries, nor one the
      caller used twice.

  The verbs `:control` and `:release`, and labels starting with `auto-`,
  are refused with `{:error, :reserved}`, before anything is submitted.

  ## Replies

  `act/3`, `stop/2` and `percepts/1` reply `{:ok, report}`:

      %{
        status: :done | :failed | :interrupted | :still_going | :yielded | :idle,
        percepts: [%Avwe.Percept{}],   # since the previous call returned, in order
        plan: [{verb, opts}],          # steps not yet submitted
        action: %{ref, verb, target} | nil,  # the step under way, or the body's own doing
        abandoned: [{verb, opts}],     # steps dropped unsubmitted since the previous reply
        problem: term() | nil,         # why the Mind could not submit a step
        dropped: n                     # percepts lost to the buffer bound
      }

  `abandoned` are the steps of a plan that were never submitted because
  the plan ended early: a step failed, the routine took the body back
  (`:yielded`), or a new `act/3` replaced the plan. `problem` is set when
  the Mind itself could not submit a step of the plan (a name that matches
  more than one thing, `{:ambiguous, query, names}`, or the session's
  refusal); that step and the rest are then `abandoned` and the plan
  `:failed`. When it is the act's first step, `act/3` fails with the
  problem instead.

  `action` is the plan's step under way or, when there is none, the
  durative action a step of the Mind's started that the body is still
  doing (a wait that an instant step, such as speaking, did not end, or a
  step under way when the routine took the body back). It is `nil` only
  when the body is doing nothing the Mind asked for. It carries `label`
  when the step had a `:ref`.

  The buffer holds at most 500 percepts; when it overflows the oldest are
  dropped and counted in the next reply's `dropped`.

  Percepts arrive from the session a step's worth at a time, and the Mind
  takes each batch whole before it answers a waiting caller, so whatever
  the body perceived in the step that ended the wait (a discovery in the
  step a journey arrives) is in that answer. When a step's batch both ends
  the plan and holds something that would interrupt, the plan's end is the
  status.

  Between calls the Mind keeps going: as each step succeeds it submits the
  next, so a plan runs while the program thinks, and a failed step drops
  the rest. Only one call waits at a time: a call made while another waits
  answers the waiting one first, as if its wait had run out. A caller
  whose process dies while it waits (its connection dropped) is
  forgotten, and what it would have been told waits for the next call.
  The Mind does not see an MCP client's `notifications/cancelled`: such a
  call waits out its course and its answer goes nowhere.

  A waiting caller is present: its act marked the session present, and the
  Mind marks it again (`Avwe.Session.touch/1`) every half `:idle_after`
  while the wait lasts, so a long wait does not hand the body to its
  routine.

  When the session yields the body to its routine (its idle rule: no call
  for `:idle_after`), the plan ends there, as `:yielded`: the routine took
  the body back while the program was away from the keyboard, and only the
  program's next act takes it back. The step under way stays the
  `action` until its result arrives, and that result is told in the next
  reply.

  With no call for `:quit_after` real milliseconds (default 30 minutes) the
  Mind stops and the body is released.
  """

  use GenServer, restart: :temporary

  alias Avwe.Session
  alias Avwe.Telnet.Command

  @controllers [:mcp, :arbor]
  @reserved_verbs [:control, :release]
  @named_verbs [:go, :kindle, :douse, :write, :read]
  @buffer 500
  @quit_after 30 * 60 * 1_000
  @interrupt_at 0.6
  @max_wait_ms 25_000

  @type step :: {atom(), keyword()} | {atom()}
  @type status :: :done | :failed | :interrupted | :still_going | :yielded | :idle
  @type report :: %{
          status: status(),
          percepts: [Avwe.Percept.t()],
          plan: [{atom(), keyword()}],
          action: %{ref: String.t(), verb: atom(), target: String.t() | nil} | nil,
          abandoned: [{atom(), keyword()}],
          problem: term() | nil,
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

  @spec start_link(keyword()) :: GenServer.on_start()
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

  Submits the first step at once, replacing any plan the Mind was running
  (its unsubmitted steps are reported as `abandoned`; a durative action
  under way goes on unless the new step replaces it, as any new durative
  action does), and replies when the first of these happens:

    * `:done` - the last step's result is a success.
    * `:failed` - a step's result is not a success; the rest of the plan is
      dropped.
    * `:interrupted` - a sensed percept at or above `:interrupt_at` arrives
      that is not about the plan's own doing (being spoken to, the river
      falling silent, a discovery, a stranger's smoke; not the smoke of a
      fire the body lit and stands beside). The action and the plan keep
      going.
    * `:yielded` - the session handed the body to its routine (see the
      moduledoc); the plan is dropped.
    * `:still_going` - `:max_wait_ms` passes. The action and the plan keep
      going.

  Options: `:interrupt_at` (salience, default #{@interrupt_at}) and
  `:max_wait_ms` (real ms, default #{@max_wait_ms}). Fails with
  `{:error, :reserved}`, `{:error, :invalid_ref}`, `{:error,
  :invalid_plan}` (not a step, or an empty plan) or `{:error,
  :invalid_options}` without submitting anything, and with `{:error,
  {:ambiguous, query, names}}` or the session's refusal when the first
  step cannot be submitted.
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
  acting. `status` is `:still_going` while a plan runs or a durative action
  a step of the Mind's started is still under way; how the last plan ended
  (`:done`, `:failed` or `:yielded`) if it ended since the previous call
  returned; and `:idle` otherwise.
  """
  @spec percepts(pid()) :: {:ok, report()}
  def percepts(mind), do: GenServer.call(mind, :percepts)

  @doc "The id of the Mind's body."
  @spec body(pid()) :: String.t()
  def body(mind), do: GenServer.call(mind, :body)

  @doc """
  Ends the Mind; its session closes and the body goes back to its routine.
  A Mind that has already ended is no error.
  """
  @spec close(pid()) :: :ok
  def close(mind) do
    GenServer.stop(mind)
  catch
    :exit, _gone -> :ok
  end

  @impl GenServer
  def init(opts) do
    controller = Keyword.get(opts, :controller, :mcp)
    body = Keyword.fetch!(opts, :body)

    connect =
      [body: body, controller: controller, sink: self()] ++
        Keyword.take(opts, [:idle_after])

    with :ok <- check_controller(controller),
         {:ok, session} <- Avwe.connect(Keyword.fetch!(opts, :world), connect) do
      Process.monitor(session)
      idle_after = Keyword.get(opts, :idle_after, Session.default_idle_after())

      state = %{
        session: session,
        body: body,
        looked: false,
        away: nil,
        buffer: :queue.new(),
        buffered: 0,
        dropped: 0,
        plan: [],
        abandoned: [],
        problem: nil,
        current: nil,
        doing: nil,
        pending: %{},
        ended: nil,
        waiter: nil,
        presence_every: max(div(idle_after, 2), 1),
        quit_after: Keyword.get(opts, :quit_after, @quit_after),
        quit_tag: nil,
        quit_timer: nil
      }

      {:ok, arm_quit(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:look, _from, state) do
    {reply, state} =
      case session_look(state) do
        {{:ok, look}, state} -> {{:ok, first_away(look, state)}, state}
        {error, state} -> {error, state}
      end

    {:reply, reply, arm_quit(%{state | looked: true, away: nil})}
  end

  def handle_call(:body, _from, state), do: {:reply, state.body, state}

  def handle_call(:percepts, _from, state) do
    state = answer_waiter(state)
    touch(state)

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
      state = answer_waiter(state)
      replaced = state.abandoned ++ state.plan
      state = %{state | plan: plan, abandoned: replaced, current: nil, ended: nil}

      case submit_next(state) do
        {:ok, state} ->
          {:noreply, state |> wait(from, interrupt_at, max_wait) |> arm_quit()}

        # The caller is told why; its plan is not counted as abandoned.
        {:error, reason, state} ->
          {:reply, {:error, reason}, arm_quit(%{state | abandoned: replaced})}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_quit(state)}
    end
  end

  @impl GenServer
  def handle_info({:avwe_percepts, session, percepts}, %{session: session} = state) do
    state = Enum.reduce(percepts, state, &buffer_percept(&2, &1))
    {state, interrupted} = Enum.reduce(percepts, {state, false}, &take/2)
    {:noreply, wake(state, interrupted)}
  end

  def handle_info({:max_wait, tag}, %{waiter: %{tag: tag}} = state),
    do: {:noreply, reply(state, :still_going)}

  def handle_info({:max_wait, _stale}, state), do: {:noreply, state}

  def handle_info({:presence, tag}, %{waiter: %{tag: tag}} = state) do
    touch(state)
    {:noreply, present(state, tag)}
  end

  def handle_info({:presence, _stale}, state), do: {:noreply, state}

  def handle_info({:quit, tag}, %{quit_tag: tag, waiter: nil} = state),
    do: {:stop, :normal, state}

  def handle_info({:quit, _stale_or_waiting}, state), do: {:noreply, state}

  # The waiting caller is gone (its connection dropped): what it would have
  # been told stays buffered for the next call.
  def handle_info(
        {:DOWN, monitor, :process, _caller, _reason},
        %{waiter: %{monitor: monitor}} = state
      ),
      do: {:noreply, arm_quit(%{state | waiter: nil})}

  def handle_info({:DOWN, _ref, :process, session, _reason}, %{session: session} = state) do
    if state.waiter, do: GenServer.reply(state.waiter.from, {:error, :session_closed})
    {:stop, :normal, %{state | waiter: nil}}
  end

  # Waiting

  defp wait(state, from, interrupt_at, max_wait) do
    tag = make_ref()
    Process.send_after(self(), {:max_wait, tag}, max_wait)
    {caller, _tag} = from
    monitor = Process.monitor(caller)

    present(
      %{state | waiter: %{from: from, interrupt_at: interrupt_at, tag: tag, monitor: monitor}},
      tag
    )
  end

  defp present(state, tag) do
    Process.send_after(self(), {:presence, tag}, state.presence_every)
    state
  end

  # After a whole batch: the plan's end answers a waiting caller before an
  # interruption does.
  defp wake(%{waiter: nil} = state, _interrupted), do: state
  defp wake(%{ended: ended} = state, _interrupted) when ended != nil, do: reply(state, ended)
  defp wake(state, true), do: reply(state, :interrupted)
  defp wake(state, false), do: state

  # Percepts

  # Each percept of a batch, already buffered, may move what the Mind
  # follows, settle the plan's current step or interrupt a waiting caller.
  defp take(percept, {state, interrupted}) do
    state = follow(state, percept)
    current = state.current

    state =
      cond do
        percept.type == :control_released ->
          yielded(state)

        current != nil and percept.kind == :result and percept.intent == current.ref ->
          settle(state, percept.outcome)

        true ->
          state
      end

    {state, interrupted or interrupts?(percept, state)}
  end

  defp settle(%{plan: []} = state, :success), do: finish(state, :done)

  defp settle(state, :success) do
    case submit_next(state) do
      {:ok, state} -> state
      {:error, reason, state} -> finish(%{state | problem: reason}, :failed)
    end
  end

  defp settle(state, _not_success), do: finish(state, :failed)

  # Only what the body senses of the world can interrupt: not the plan's
  # results or progress, not the body's own doings that it senses (its
  # fires carry an issuer), and not the smoke of a fire it lit and stands
  # beside.
  defp interrupts?(_percept, %{waiter: nil}), do: false

  defp interrupts?(percept, %{waiter: %{interrupt_at: interrupt_at}}) do
    percept.kind == :sensed and percept.issuer == nil and not own_fire?(percept) and
      percept.salience >= interrupt_at
  end

  defp own_fire?(%{data: %{own_fire: true}}), do: true
  defp own_fire?(_percept), do: false

  # What the body is doing for the Mind: the durative action of any step it
  # submitted, from its start until its result, which may outlive the plan
  # that asked for it. Every ref submitted is pending until its result.
  defp follow(%{pending: pending} = state, %{type: :action_started, intent: ref})
       when is_map_key(pending, ref),
       do: %{state | doing: pending[ref]}

  defp follow(%{pending: pending} = state, %{kind: :result, intent: ref})
       when is_map_key(pending, ref) do
    doing = if match?(%{ref: ^ref}, state.doing), do: nil, else: state.doing
    %{state | pending: Map.delete(pending, ref), doing: doing}
  end

  defp follow(state, _percept), do: state

  # The session yielded the body to its routine: the plan ends, and the
  # routine, not the Mind, decides what the body does until the next act.
  # The step under way is still the body's doing until its result says
  # otherwise.
  defp yielded(%{current: nil} = state),
    do: %{state | plan: [], abandoned: state.abandoned ++ state.plan}

  defp yielded(%{current: current} = state) do
    doing = if Map.has_key?(state.pending, current.ref), do: current, else: state.doing
    finish(%{state | doing: doing}, :yielded)
  end

  defp buffer_percept(%{buffered: @buffer} = state, percept) do
    {_oldest, queue} = :queue.out(state.buffer)
    %{state | buffer: :queue.in(percept, queue), dropped: state.dropped + 1}
  end

  defp buffer_percept(state, percept),
    do: %{state | buffer: :queue.in(percept, state.buffer), buffered: state.buffered + 1}

  defp flush(state) do
    %{
      state
      | buffer: :queue.new(),
        buffered: 0,
        dropped: 0,
        ended: nil,
        abandoned: [],
        problem: nil
    }
  end

  # The plan

  # A step that cannot be submitted ends the plan there: it and the rest
  # are abandoned.
  defp submit_next(%{plan: [{verb, opts} | rest] = plan} = state) do
    ref = new_ref()

    with {{:ok, target}, state} <- target(state, verb, opts),
         {:ok, ^ref} <- Session.act(state.session, verb, act_opts(ref, target, opts)) do
      action = labelled(%{ref: ref, verb: verb, target: target}, opts[:ref])
      {:ok, %{state | plan: rest, current: action, pending: Map.put(state.pending, ref, action)}}
    else
      {{:error, reason}, state} -> {:error, reason, abandon(state, plan)}
      {:error, reason} -> {:error, reason, abandon(state, plan)}
    end
  end

  defp abandon(state, plan),
    do: %{state | plan: [], current: nil, abandoned: state.abandoned ++ plan}

  defp act_opts(ref, target, opts) do
    [ref: ref, target: target] ++
      if Keyword.has_key?(opts, :params), do: [params: opts[:params]], else: []
  end

  # Unique across runs of the server too: a durative action outlives a
  # restart on its body, and its result must never be taken for another's.
  defp new_ref, do: "m-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp labelled(action, nil), do: action
  defp labelled(action, label), do: Map.put(action, :label, label)

  # A step's target, a name resolved against a fresh look when it is one.
  defp target(state, verb, opts) do
    case opts[:target_name] || opts[:target] do
      query when verb in @named_verbs and is_binary(query) ->
        case session_look(state) do
          {{:ok, look}, state} -> {resolve(query, candidates(verb, look)), state}
          {_error, state} -> {{:ok, query}, state}
        end

      _no_name ->
        {{:ok, opts[:target]}, state}
    end
  end

  # Against each list of candidates in turn: the first that names the query
  # decides. A name that matches nothing goes to the world as given.
  defp resolve(query, []), do: {:ok, query}

  defp resolve(query, [candidates | others]) do
    case Command.resolve(query, candidates) do
      {:ok, id} -> {:ok, id}
      {:ambiguous, names} -> {:error, {:ambiguous, query, Enum.sort(names)}}
      :none -> resolve(query, others)
    end
  end

  defp candidates(:go, look) do
    here = if look[:here], do: [{look.here.id, look.here.name}], else: []
    [Enum.map(look[:places] || [], &{&1.id, &1.name}) ++ here]
  end

  defp candidates(verb, look) when verb in [:kindle, :douse] do
    [
      Enum.map(look[:hearths] || [], &{&1.id, &1.name}),
      for(%{ref: id, name: name} when is_binary(name) <- look[:fires] || [], do: {id, name})
    ]
  end

  defp candidates(_notebook_verb, look),
    do: [for(%{kind: :notebook} = item <- look[:carried] || [], do: {item.id, item.name})]

  # The plan ends: what was left of it is abandoned.
  defp finish(state, status) do
    %{state | plan: [], abandoned: state.abandoned ++ state.plan, current: nil, ended: status}
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
      abandoned: state.abandoned,
      problem: state.problem,
      dropped: state.dropped
    }
  end

  defp plan({_verb, _opts} = step), do: plan([step])
  defp plan({_verb} = step), do: plan([step])
  defp plan([_step | _rest] = steps), do: steps |> Enum.map(&step/1) |> all_steps()
  defp plan(_other), do: {:error, :invalid_plan}

  defp step({verb}), do: step({verb, []})

  defp step({verb, opts}) when is_atom(verb) and is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_plan}

      verb in @reserved_verbs ->
        {:error, :reserved}

      not string_or_nil?(opts[:target_name]) ->
        {:error, :invalid_plan}

      true ->
        label(opts[:ref], {verb, Keyword.take(opts, [:target, :target_name, :params, :ref])})
    end
  end

  defp step(_other), do: {:error, :invalid_plan}

  defp label(nil, step), do: {:ok, step}
  defp label("auto-" <> _rest, _step), do: {:error, :reserved}
  defp label(label, step) when is_binary(label), do: {:ok, step}
  defp label(_label, _step), do: {:error, :invalid_ref}

  defp string_or_nil?(value), do: value == nil or is_binary(value)

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

  # The session's look. Its first one carries what the body did before the
  # session took it; if the Mind looks for itself (to resolve a name)
  # before the program's first look, that is kept for the program.
  defp session_look(state) do
    case Session.look(state.session) do
      {:ok, look} when not state.looked and state.away == nil ->
        {{:ok, look}, %{state | away: look.away}}

      reply ->
        {reply, state}
    end
  end

  defp first_away(look, %{looked: true}), do: %{look | away: []}
  defp first_away(look, %{away: away}) when away != nil, do: %{look | away: away}
  defp first_away(look, _state), do: look

  # Marks the controller present. A session that has just gone is no error
  # here: its DOWN ends the Mind.
  defp touch(state) do
    Session.touch(state.session)
  catch
    :exit, _gone -> :ok
  end

  defp arm_quit(state) do
    if state.quit_timer, do: Process.cancel_timer(state.quit_timer)
    tag = make_ref()
    timer = Process.send_after(self(), {:quit, tag}, state.quit_after)
    %{state | quit_tag: tag, quit_timer: timer}
  end
end
