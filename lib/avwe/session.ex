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

  `peek/1` is a look that is not presence, for a client that redraws as the
  world moves and would otherwise keep the body in hand for ever.

  **While you were away.** A body's look carries `away`, what it perceived
  while nobody held it (`Avwe.Perception.away/2`), which is empty once a
  controller holds it. The session takes the body only at the next step,
  and a live clock may step before the controller's first look, so the
  session reads `away` from the world as it found it on connecting, before
  it submitted `:control`, and its first `look/1` returns that. Later looks
  show the world's own: empty while held, what the routine did since the
  session yielded while yielded.

  **Guests.** A session opened with `guest: [name: ..., backstory: ...]` and no
  body is for a body that does not exist yet (`Avwe.Guests`, `docs/m3-spec.md`):
  it claims the lease for the guest's id, asks the region to take its arrival
  (`:arrive`, refused at once with the reason if the name is not free or the
  world is full) and then takes the body as for any. The body exists after the
  next step. Until then `look/1` answers `{:error, :arriving}`, and
  `await_arrival/2` waits for it; the arrival's result, like the lease's, is
  the session's own and never reaches the controller. `body:` and `guest:`
  together are `{:error, :body_and_guest}`, and a world that takes no guests
  (`Avwe.start_world/2`, `:guests`) answers `{:error, :no_guests}`.

  **The world.** A session lives no longer than its world: when the world
  stops, the session stops too, so its lease and its subscription, both
  keyed by the world's name, are not left behind for a world started again
  under that name. It does not release the body then: its release would
  reach whatever world runs under that name by the time it is sent. The
  body's holder stays written on it, and the world, when it starts again,
  releases every body that no live lease holds (`Avwe.RegionServer`).

  ## Scenes

  A session opened with `scenes: true` also tells its controller what its
  body can see, as `Avwe.Scene`s, for a client that draws. `scene/1` returns
  the current one, for the first draw, and from then on the session sends its
  sink `{:avwe_scene, session, scene}` after a step that changed it (the body
  moved, sight changed by half a cell or more, something in sight moved or
  changed, a reach started or stopped running), and never when nothing did.
  Whoever holds the body is part of a scene, so a hand-over changes it.

  Each scene is whole, and replaces the one before. Nothing is sent before
  the first `scene/1`, so a client's first scene is the one it asked for and
  never an older one already on its way; after that a client that asks again
  keeps whichever has the later `time`. A scene follows the percepts of its
  step, so a client never draws a world ahead of the words about it. The
  session never waits on its sink, so a client that falls behind should draw
  only the newest scene it has.

  Scenes draw the ground from a map that is built once for each terrain and
  kept (`Avwe.GroundCache`). The session asks for it as it starts. The first
  time anyone does, it takes about a second for the Ember Reach, and the
  session does not wait: its scenes show what is in sight and no ground
  (`rows` is `nil`) until the map is built, and the first with the ground
  follows at once.

  A spectator opened with `scenes: true` (no body) is given the other lens:
  an `Avwe.WorldScene`, the whole valley and everything in it with its fields,
  and the same messages. It is built from the published snapshot, which has the
  fields the step's own view leaves out, and sent only when it is the snapshot
  of the step the percepts describe, so a spectator's scene is never ahead of the
  words about it either. Its ground never changes, so it is not part of the
  scene: `ground/1` gives it once, as an `Avwe.WorldGround`.

  A session without `scenes: true` has none, and `scene/1` gives `nil`. A
  telnet or MCP spectator behaves as it always has.

  Start sessions with `Avwe.connect/2`.
  """

  use GenServer, restart: :temporary

  alias Avwe.{
    Event,
    GroundCache,
    Guests,
    Intent,
    Perception,
    RegionServer,
    Scene,
    Terrain,
    World,
    WorldGround,
    WorldScene
  }

  @region {0, 0}
  @idle_after 10 * 60 * 1_000
  @controllers [:human, :mcp, :arbor]
  @reserved_verbs [:control, :release, :arrive]
  @reserved_ref "auto-"
  @announced %{control_released: :yield, control_taken: :retake}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "How long a session waits for a call before it yields the body, by default (real ms)."
  @spec default_idle_after() :: pos_integer()
  def default_idle_after, do: @idle_after

  @doc "What the body senses right now and what it can do. See `Avwe.Perception.look/2`."
  @spec look(pid()) :: {:ok, map()} | {:error, term()}
  def look(session), do: GenServer.call(session, :look)

  @doc """
  The look, for a client that keeps its view of the body fresh by itself, as a
  page does while the world moves. Unlike `look/1` it does not mark the
  controller present, so it does not keep the body in hand, and it carries no
  `away`: only `look/1` tells that, once.
  """
  @spec peek(pid()) :: {:ok, map()} | {:error, term()}
  def peek(session), do: GenServer.call(session, :peek)

  @doc """
  What the body can see now, as an `Avwe.Scene`: the first draw of a session
  opened with `scenes: true`, and a fresh one whenever a client wants it.
  Later scenes are sent when they change (see "Scenes" above). For a spectator
  with scenes it is an `Avwe.WorldScene`. `nil` for a session without scenes
  and a body that is nowhere. Marks the controller present, like `look/1`.
  """
  @spec scene(pid()) :: {:ok, Scene.t() | WorldScene.t() | nil} | {:error, term()}
  def scene(session), do: GenServer.call(session, :scene)

  @doc """
  The ground of the whole map (`Avwe.WorldGround`), for a spectator with scenes
  to give its client once: it never changes, so no scene carries it. `nil` for
  any other session and for a world with no terrain. The first request for a
  terrain builds it, which takes about a second for the Ember Reach; the
  session goes on meanwhile.
  """
  @spec ground(pid()) :: {:ok, WorldGround.t() | nil} | {:error, term()}
  def ground(session), do: GenServer.call(session, :ground, 15_000)

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

  @doc """
  Waits, up to `timeout` real milliseconds, for the session's guest to arrive:
  the step after its arrival was asked for, which on a clock stepped by hand
  is whenever the world is stepped. `:ok` at once for any body that exists.
  """
  @spec await_arrival(pid(), timeout()) :: :ok | {:error, :timeout}
  def await_arrival(session, timeout \\ 10_000),
    do: GenServer.call(session, {:await_arrival, timeout}, add_second(timeout))

  defp add_second(:infinity), do: :infinity
  defp add_second(timeout), do: timeout + 1_000

  @doc "Ends the session and releases its body."
  @spec close(pid()) :: :ok
  def close(session), do: GenServer.stop(session)

  @impl GenServer
  def init(opts) do
    world = Keyword.fetch!(opts, :world)
    controller = Keyword.get(opts, :controller, :human)

    with :ok <- check_controller(controller),
         {:ok, world_pid} <- whereis(world),
         {:ok, view} <- snapshot(world),
         {:ok, body, guest} <- body_or_guest(world, opts),
         :ok <- check_body(view, body, guest),
         :ok <- claim(world, world_pid, body, controller, guest),
         scenes = opts[:scenes] == true,
         {:ok, arrival} <- subscribe_and_arrive(world, body, guest, controller, scenes) do
      sink = Keyword.fetch!(opts, :sink)
      Process.monitor(sink)
      Process.monitor(world_pid)

      state = %{
        world: world,
        world_pid: world_pid,
        body: body,
        controller: controller,
        sink: sink,
        terrain: view.terrain,
        next_ref: 1,
        next_percept: 1,
        idle_after: Keyword.get(opts, :idle_after, @idle_after),
        idle_tag: nil,
        yielded: false,
        lease_refs: if(arrival, do: %{arrival => :arrive}, else: %{}),
        arrival: arrival,
        arrived: arrival == nil,
        waiting: %{},
        away: if(body != nil and guest == nil, do: Perception.away(view, body)),
        scenes: scenes,
        ground: nil,
        last_scene: nil
      }

      {:ok, state |> load_ground() |> take_control(:take) |> arm_idle()}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:look, _from, %{arrived: false} = state),
    do: {:reply, {:error, :arriving}, arm_idle(state)}

  def handle_call(:look, _from, state) do
    reply =
      with {:ok, view} <- snapshot(state.world) do
        {:ok, view |> Perception.look(state.body) |> arrival(state.away)}
      end

    {:reply, reply, arm_idle(%{state | away: nil})}
  end

  def handle_call(:peek, _from, %{arrived: false} = state),
    do: {:reply, {:error, :arriving}, state}

  def handle_call(:peek, _from, state) do
    reply =
      with {:ok, view} <- snapshot(state.world) do
        {:ok, view |> Perception.look(state.body) |> Map.replace(:away, [])}
      end

    {:reply, reply, state}
  end

  def handle_call(:scene, _from, %{scenes: false} = state),
    do: {:reply, {:ok, nil}, arm_idle(state)}

  def handle_call(:scene, _from, %{arrived: false} = state),
    do: {:reply, {:ok, nil}, arm_idle(state)}

  def handle_call(:scene, _from, state) do
    case snapshot(state.world) do
      {:ok, view} ->
        scene = build_scene(state, view)
        {:reply, {:ok, scene}, arm_idle(%{state | last_scene: scene || state.last_scene})}

      {:error, _gone} = error ->
        {:reply, error, arm_idle(state)}
    end
  end

  def handle_call(
        :ground,
        from,
        %{scenes: true, body: nil, terrain: %Terrain{} = terrain} = state
      ) do
    if GroundCache.world_cached?(terrain) do
      {:reply, {:ok, GroundCache.world(terrain)}, state}
    else
      {:ok, _task} =
        Task.start(fn -> GenServer.reply(from, {:ok, GroundCache.world(terrain)}) end)

      {:noreply, state}
    end
  end

  def handle_call(:ground, _from, state), do: {:reply, {:ok, nil}, state}

  def handle_call({:await_arrival, _timeout}, _from, %{arrived: true} = state),
    do: {:reply, :ok, state}

  def handle_call({:await_arrival, timeout}, from, state) do
    waiting = Map.put(state.waiting, from, timer(from, timeout))
    {:noreply, %{state | waiting: waiting}}
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

  @impl GenServer
  def handle_info({:avwe_events, world, events, view}, %{world: world} = state) do
    if exists?(view, state.body) do
      view = Map.put(view, :terrain, state.terrain)
      events = Enum.reject(events, &foreign_lease?(&1, state.lease_refs))
      percepts = Perception.percepts(view, state.body, events)
      {own, percepts} = Enum.split_with(percepts, &Map.has_key?(state.lease_refs, &1.intent))
      settled = Enum.map(own, &Map.fetch!(state.lease_refs, &1.intent))
      percepts = Enum.filter(percepts, &announced?(&1, settled))
      state = %{state | lease_refs: Map.drop(state.lease_refs, Enum.map(own, & &1.intent))}

      case settle_arrival(state, own) do
        {:ok, state} -> {:noreply, state |> deliver(percepts) |> push_scene(view)}
        {:refused, state} -> {:stop, :normal, state}
      end
    else
      # A guest's body is not in the world until the step of its arrival.
      {:noreply, state}
    end
  end

  def handle_info({:arrival_timeout, from}, state) do
    case Map.fetch(state.waiting, from) do
      {:ok, _timer} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: Map.delete(state.waiting, from)}}

      :error ->
        {:noreply, state}
    end
  end

  # The ground map is built: the first scene with ground follows.
  def handle_info({:ground, ground}, state) do
    state = %{state | ground: ground}

    case snapshot(state.world) do
      {:ok, view} -> {:noreply, push_scene(state, view)}
      {:error, _gone} -> {:noreply, state}
    end
  end

  def handle_info({:idle, tag}, %{idle_tag: tag} = state) do
    {:noreply, yield(state)}
  end

  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, sink, _reason}, %{sink: sink} = state) do
    {:stop, :normal, state}
  end

  # The world stopped: nothing is left to release, and a world started again
  # under its name must not get this session's release.
  def handle_info({:DOWN, _ref, :process, world_pid, _reason}, %{world_pid: world_pid} = state) do
    {:stop, :normal, %{state | world_pid: nil}}
  end

  @impl GenServer
  def terminate(_reason, %{body: body, yielded: false, world_pid: pid} = state)
      when body != nil and pid != nil do
    release(state, :close)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # A guest arrives with the step that applies its `:arrive`, whose result is
  # the session's own: the waiters are answered, or the session ends if the
  # world refused after all (what `Avwe.RegionServer` checked has changed
  # in between, which only a world restarted under other settings can do).
  defp settle_arrival(%{arrival: nil} = state, _own), do: {:ok, state}

  defp settle_arrival(%{arrival: ref} = state, own) do
    case Enum.find(own, &(&1.intent == ref)) do
      nil ->
        {:ok, state}

      %{outcome: :success} ->
        {:ok, answer_waiting(%{state | arrival: nil, arrived: true}, :ok)}

      _refused ->
        {:refused, answer_waiting(state, {:error, :refused})}
    end
  end

  defp answer_waiting(state, reply) do
    for {from, timer} <- state.waiting do
      if timer, do: Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end

    %{state | waiting: %{}}
  end

  defp timer(_from, :infinity), do: nil
  defp timer(from, ms), do: Process.send_after(self(), {:arrival_timeout, from}, ms)

  # Whether the body is in the world: a spectator has none, and a guest has
  # none until its arrival's step.
  defp exists?(_view, nil), do: true
  defp exists?(view, body), do: Map.has_key?(Map.get(view.components, :body, %{}), body)

  # The first look tells what happened before the session took the body.
  defp arrival(look, nil), do: look
  defp arrival(look, away), do: %{look | away: away}

  defp deliver(state, []), do: state

  defp deliver(state, percepts) do
    numbered = Enum.with_index(percepts, state.next_percept)

    send(
      state.sink,
      {:avwe_percepts, self(), Enum.map(numbered, fn {p, n} -> %{p | id: "p-#{n}"} end)}
    )

    %{state | next_percept: state.next_percept + length(percepts)}
  end

  # Scenes

  # The ground map, at once if it is built already, and otherwise in the
  # background so that connecting never waits on the first build of a big map.
  defp load_ground(%{body: nil} = state), do: state

  defp load_ground(%{scenes: true, terrain: %Terrain{} = terrain} = state) do
    if GroundCache.cached?(terrain) do
      %{state | ground: GroundCache.fetch(terrain)}
    else
      session = self()
      Task.start(fn -> send(session, {:ground, GroundCache.fetch(terrain)}) end)
      state
    end
  end

  defp load_ground(state), do: state

  defp build_scene(%{body: nil}, snapshot), do: WorldScene.build(snapshot)

  defp build_scene(state, view),
    do: view |> Map.put(:ground, state.ground) |> Scene.build(state.body)

  # The controller is sent a scene only once it has been given one
  # (`scene/1`), and only when this one differs from the last it was given.
  defp push_scene(%{last_scene: nil} = state, _view), do: state

  # A spectator's scene is made of the fields, which the step's view leaves out,
  # so it is read from the snapshot: and only if that is the step these percepts
  # are of. A snapshot already a step ahead is left to the next message, which
  # comes with its own percepts, so the scene is never ahead of the words.
  defp push_scene(%{body: nil} = state, view) do
    case snapshot(state.world) do
      {:ok, %{step: step} = snapshot} when step == view.step ->
        push(state, build_scene(state, snapshot))

      _ahead_or_gone ->
        state
    end
  end

  defp push_scene(state, view), do: push(state, build_scene(state, view))

  defp push(state, scene) do
    if scene != nil and not same_view?(scene, state.last_scene) do
      send(state.sink, {:avwe_scene, self(), scene})
      %{state | last_scene: scene}
    else
      state
    end
  end

  defp same_view?(%Scene{} = a, %Scene{} = b), do: Scene.same_view?(a, b)
  defp same_view?(%WorldScene{} = a, %WorldScene{} = b), do: WorldScene.same_view?(a, b)
  defp same_view?(_scene, _other), do: false

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

  # Another session's lease intents for this body: one that ended with its
  # world left its control or release in the journal, and the world started
  # again settles it. Their results are that session's, not this one's.
  defp foreign_lease?(%Event{type: :action_result, data: %{verb: verb, ref: ref}}, lease_refs)
       when verb in @reserved_verbs,
       do: not Map.has_key?(lease_refs, ref)

  defp foreign_lease?(_event, _lease_refs), do: false

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

  defp whereis(world) do
    case Avwe.World.whereis(world) do
      nil -> {:error, :no_such_world}
      pid -> {:ok, pid}
    end
  end

  defp snapshot(world) do
    case RegionServer.snapshot(world, @region) do
      {:ok, view} -> {:ok, view}
      {:error, :not_found} -> {:error, :no_such_world}
    end
  end

  defp check_controller(controller) when controller in @controllers, do: :ok
  defp check_controller(_controller), do: {:error, :invalid_controller}

  # The body a session is for, or the guest it asks to be: `{:ok, body,
  # guest}`, where `guest` is the offer with the world's settings
  # (`Avwe.Guests`), or `nil` for a body that is there already.
  defp body_or_guest(world, opts) do
    case {opts[:body], opts[:guest]} do
      {body, nil} -> {:ok, body, nil}
      {nil, guest} -> offered(world, guest)
      {_body, _guest} -> {:error, :body_and_guest}
    end
  end

  defp offered(world, guest) when is_list(guest) or is_map(guest) do
    with {:ok, info} <- world_info(world),
         %{arrival: arrival, max: max} <- info[:guests] || {:error, :no_guests},
         {:ok, offer} <- Guests.offer(guest[:name], guest[:backstory]) do
      {:ok, offer.id, Map.merge(offer, %{arrival: arrival, max: max})}
    end
  end

  defp offered(_world, _guest), do: {:error, :invalid_name}

  defp world_info(world) do
    case World.info(world) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, :no_such_world}
    end
  end

  defp check_body(_view, nil, _guest), do: :ok
  defp check_body(_view, _body, guest) when guest != nil, do: :ok

  # A body that is nowhere, because its character's home is not on the map
  # (`Avwe.Quire.Seed.unplaced/1`), has no position to perceive from: it cannot
  # be played, whoever asks, and nothing is claimed for it.
  defp check_body(view, body, nil) do
    cond do
      not Map.has_key?(Map.get(view.components, :body, %{}), body) -> {:error, :no_such_body}
      not Map.has_key?(Map.get(view.components, :position, %{}), body) -> {:error, :elsewhere}
      true -> :ok
    end
  end

  defp claim(_world, _world_pid, nil, _controller, _guest), do: :ok

  # The lease names the world it was taken in, by pid, so a world started
  # again under the same name can tell a session of its own from one of the
  # world before that has not ended yet (`Avwe.RegionServer`).
  defp claim(world, world_pid, body, controller, guest) do
    case Registry.register(Avwe.Registry, {:lease, world, body}, {controller, world_pid}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _holder}} -> {:error, taken(guest)}
    end
  end

  # Somebody else is that guest, or arriving as one: the name is not free.
  defp taken(nil), do: :body_taken
  defp taken(_guest), do: :name_taken

  # Subscribed before the arrival is asked for, so that the step that makes
  # the guest is heard of. If either fails the session never starts, and the
  # lease it has just claimed is let go of here, before the caller is told: left
  # to the Registry, which notices that a process has gone only a little later,
  # the name would still be taken for a retry made at that moment.
  defp subscribe_and_arrive(world, body, guest, controller, scenes) do
    with {:ok, _owner} <- Avwe.subscribe(world, steps: scenes),
         {:ok, arrival} <- arrive(world, body, guest, controller) do
      {:ok, arrival}
    else
      {:error, _reason} = refused ->
        unclaim(world, body)
        refused
    end
  end

  defp unclaim(_world, nil), do: :ok

  defp unclaim(world, body) do
    Registry.unregister(Avwe.Registry, {:lease, world, body})
    :ok
  end

  # Asks the region for the guest's arrival: refused with the reason before
  # anything is journaled if the name is not free or the world is full.
  defp arrive(_world, _body, nil, _controller), do: {:ok, nil}

  defp arrive(world, body, guest, controller) do
    ref = "arrive-#{System.unique_integer([:positive])}"
    params = Map.take(guest, [:name, :backstory, :arrival, :max])
    intent = Intent.new(body, :arrive, ref: ref, controller: controller, params: params)

    case RegionServer.submit(world, @region, intent) do
      :ok -> {:ok, ref}
      {:error, :not_found} -> {:error, :no_such_world}
      {:error, _reason} = refused -> refused
    end
  end
end
