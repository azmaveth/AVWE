defmodule Avwe.RegionServer do
  @moduledoc """
  Runs one `Avwe.Region` as a process.

  After every advance it publishes a snapshot to an ETS table it owns, so
  readers never block the tick and never call this process. Events go to
  subscribers registered with `Avwe.subscribe/2`, together with a view of the
  state they happened in (`Avwe.Region.view/1`); a step with no events is told
  only to those that asked to hear of every step. Inputs (`Avwe.Input`) queue in
  the region's inbox until the next step.

  With a `:store` dir the region persists itself through `Avwe.Store`: every
  input is journaled as it is accepted, every advance is appended to the log
  before it is published, and a snapshot is written whenever an advance
  crosses a multiple of `:snapshot_every` steps (a multi-step advance that
  crosses one snapshots at the end of that advance). `:snapshot_keep` is how
  many of the newest snapshots to keep besides the first.

  A region that starts with saved state resumes from it; that is how a world
  restarts, and how the supervisor brings a crashed region back where it was.
  The saved state wins for state (seed, time, terrain, components, fields,
  env), but the systems come from the region the server was given: they are
  code, not state, and the rules may change while the world runs.

  What the region was built from is checked first. A world built from a
  definition (`Avwe.Definition`) passes the hash of it as `:definition`, and
  every snapshot records it: a saved world is resumed only under the
  definition it was saved under, and refuses to start under another, or under
  none (`{:definition_changed, saved, given}`), since the saved state belongs
  to the world that definition described. A world built without a definition
  has the region it was given ignored where it differs, and the layers above say
  so (`Avwe.Hooks`: `on_reconfigure/3`).

  What those layers need done when a region has been started again (a hold that
  nobody keeps any more, for the agent layer) is theirs to say too, as inputs that
  are accepted and journaled as if they had come from outside
  (`Avwe.Hooks`: `on_resume/2`).

  A log is only valid under the systems it was recorded with, and replay
  runs the systems of the snapshot it starts from. So when the systems
  change on a resume, the reconfigured region is snapshotted at once: the
  log from that point belongs to the new rules, and a crash before the next
  regular snapshot replays the gap under them, not the old ones.
  """

  use GenServer

  alias Avwe.{Input, Region, Store}

  require Logger

  @default_snapshot_every 1_000
  @default_snapshot_keep 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    region = Keyword.fetch!(opts, :region)
    %{id: {__MODULE__, region.id}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Advances a region by `steps` steps and returns its new step and time."
  @spec advance(term(), term(), non_neg_integer()) ::
          {:ok, %{step: non_neg_integer(), time: integer()}} | {:error, :not_found}
  def advance(world, region_id, steps) do
    call(world, region_id, {:advance, steps}, :infinity)
  end

  @doc """
  Queues an input for the region's next step. An input that a system made
  (`Avwe.Input.derived?/1`) is refused with `{:error, :derived_input}`; the
  others are asked whether the region would take them (`Avwe.Input.validate/2`)
  and refused with the reason before anything is journaled.
  """
  @spec submit(term(), term(), Input.t()) :: :ok | {:error, :not_found | term()}
  def submit(world, region_id, input) do
    call(world, region_id, {:submit, input})
  end

  @doc "The hash of the live region's state (`Avwe.Region.state_hash/1`)."
  @spec state_hash(term(), term()) :: {:ok, String.t()} | {:error, :not_found}
  def state_hash(world, region_id) do
    call(world, region_id, :state_hash)
  end

  @doc """
  The region's latest published snapshot, with its terrain. Reads ETS; doesn't
  call the process.
  """
  @spec snapshot(term(), term()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(world, region_id) do
    with {:ok, _pid, table} <- lookup(world, region_id) do
      [{:snapshot, snapshot}] = :ets.lookup(table, :snapshot)
      [{:terrain, terrain}] = :ets.lookup(table, :terrain)
      {:ok, Map.put(snapshot, :terrain, terrain)}
    end
  end

  defp call(world, region_id, request, timeout \\ 5_000) do
    case lookup(world, region_id) do
      {:ok, pid, _table} -> GenServer.call(pid, request, timeout)
      error -> error
    end
  end

  defp lookup(world, region_id) do
    case Registry.lookup(Avwe.Registry, {:region, world, region_id}) do
      [{pid, table}] -> {:ok, pid, table}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    # So terminate/2 runs on supervisor shutdown and closes the store.
    Process.flag(:trap_exit, true)
    world = Keyword.fetch!(opts, :world)
    keep = Keyword.get(opts, :snapshot_keep, @default_snapshot_keep)

    definition = Keyword.get(opts, :definition)
    hooks = Keyword.get(opts, :hooks, [])
    config = %{world: world, keep: keep, definition: definition, hooks: hooks}

    case open_store(Keyword.get(opts, :store), Keyword.fetch!(opts, :region), config) do
      {:ok, store, region} ->
        table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
        {:ok, _owner} = Registry.register(Avwe.Registry, {:region, world, region.id}, table)
        :ets.insert(table, {:terrain, region.terrain})

        state =
          resumed_by_hooks(%{
            world: world,
            region: region,
            table: table,
            store: store,
            dir: store && store.dir,
            snapshot_every: Keyword.get(opts, :snapshot_every, @default_snapshot_every),
            snapshot_keep: keep,
            definition: definition,
            hooks: hooks
          })

        publish(table, state.region)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:store, reason}}
    end
  end

  @impl GenServer
  def handle_call({:submit, input}, _from, state) do
    with :ok <- not_derived(input),
         :ok <- Input.validate(input, state.region) do
      {:reply, :ok, accept(state, input)}
    else
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call({:advance, steps}, _from, state) do
    before = state.region
    dt = before.dt
    {events, region} = before |> Region.advance(steps, dt: dt) |> Region.drain_events()

    :ok = persist(state, before, steps, dt, events, region)
    publish(state.table, region)
    broadcast(state.world, events, Region.view(region))

    {:reply, {:ok, %{step: region.step, time: region.time}}, %{state | region: region}}
  end

  def handle_call(:state_hash, _from, state) do
    {:reply, {:ok, Region.state_hash(state.region)}, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, {:linked_process_exited, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, %{store: nil}), do: :ok
  def terminate(_reason, %{store: store}), do: Store.close(store)

  # Without a store the region starts as given. With one, saved state wins
  # over the given region, and a fresh store gets the given region as its
  # step-0 snapshot so the whole history can be replayed from it.
  defp open_store(nil, region, _config), do: {:ok, nil, region}

  defp open_store(dir, region, config) do
    with {:ok, store} <- Store.open(dir, region.id, owner: true),
         {:ok, region} <- resume(store, region, config) do
      {:ok, store, region}
    end
  end

  defp resume(store, region, config) do
    case Store.rebuild_with_definition(store) do
      {:ok, saved, saved_definition} ->
        with :ok <- same_definition(saved, saved_definition, config.definition, store.dir),
             do: resume_saved(store, saved, region, config)

      :none ->
        start_fresh(store, region, config)

      {:error, {:unknown_snapshot, path, tag}} = error ->
        Logger.error(
          "Region #{inspect(region.id)}: no snapshot this build can read; #{path} is " <>
            "tagged #{inspect(tag)} and this build reads #{inspect(Store.snapshot_tag())}. " <>
            "Delete the world folder #{store.dir} to start over."
        )

        error

      {:error, {:unknown_systems, ids}} = error ->
        Logger.error(
          "Region #{inspect(region.id)}: the world was saved with systems this build does " <>
            "not have: #{Enum.join(ids, ", ")}. Run a build that has them, or delete the " <>
            "world folder #{store.dir} to start over."
        )

        error

      {:error, _reason} = error ->
        error
    end
  end

  defp resume_saved(store, saved, given, config) do
    Logger.info("Resumed region #{inspect(saved.id)} at step #{saved.step} from #{store.path}")

    resumed = reconfigure(saved, given, store.dir, config)

    with :ok <- snapshot_if_rules_changed(store, saved, resumed, config),
         do: {:ok, resumed}
  end

  # The saved state belongs to the world its definition described, so it is
  # resumed under that definition and no other.
  defp same_definition(_saved, definition, definition, _dir), do: :ok

  defp same_definition(saved, saved_definition, definition, dir) do
    Logger.error(
      "Region #{inspect(saved.id)}: the world was saved #{described(saved_definition)} " <>
        "but is now given #{described(definition)}. Give it the definition it was " <>
        "saved under, or delete the world folder #{dir} to start over."
    )

    {:error, {:definition_changed, saved_definition, definition}}
  end

  defp described(nil), do: "without a definition (from Quire and settings)"
  defp described(hash), do: "under the definition #{String.slice(hash, 0, 12)}"

  # Replay runs the systems of the snapshot it starts from, so a log written
  # under new systems must begin at a snapshot that carries them.
  defp snapshot_if_rules_changed(_store, %{systems: same}, %{systems: same}, _config), do: :ok

  defp snapshot_if_rules_changed(store, _saved, resumed, config),
    do: Store.snapshot(store, resumed, keep: config.keep, definition: config.definition)

  # A log with no snapshot to replay it onto can't be resumed and must not be
  # started over: the world fails to start instead.
  defp start_fresh(store, region, config) do
    if Store.empty?(store),
      do:
        with(
          :ok <- Store.snapshot(store, region, keep: config.keep, definition: config.definition),
          do: {:ok, region}
        ),
      else: {:error, :log_without_snapshot}
  end

  # Configuration beats the snapshot for code; the snapshot wins for state.
  # What else of the given region differs from the saved one is for the layers
  # above to name (`Avwe.Hooks`), and ignore.
  defp reconfigure(saved, given, dir, config) do
    context = %{world: config.world, dir: dir, definition: config.definition}

    for hook <- config.hooks, hooked?(hook, :on_reconfigure, 3) do
      :ok = hook.on_reconfigure(saved, given, context)
    end

    if given.systems != saved.systems do
      Logger.info(
        "Region #{inspect(saved.id)}: systems changed from #{inspect(saved.systems)} " <>
          "to #{inspect(given.systems)}"
      )
    end

    # A system whose options changed is the same system: only the ids that are new
    # are prepared (preparing a live system again would reset what it keeps).
    known = Enum.map(saved.systems, &elem(&1, 0))
    added = for {id, _options} <- given.systems, id not in known, do: id
    Region.prepare(%{saved | systems: given.systems}, only: added)
  end

  defp hooked?(hook, callback, arity),
    do: Code.ensure_loaded?(hook) and function_exported?(hook, callback, arity)

  # An input a system made is derived state: regenerated on replay, never
  # journaled (`Avwe.Input`). It is not something to send in, and one that was
  # journaled would be numbered twice when the region is rebuilt.
  defp not_derived(input) do
    if Input.derived?(input), do: {:error, :derived_input}, else: :ok
  end

  # Queues an input for the next step and journals it.
  defp accept(state, input) do
    region = Region.submit(state.region, input)
    :ok = journal(state, region.step, region |> Region.pending() |> List.last())
    %{state | region: region}
  end

  # What the layers above ask of a region that has been started again
  # (`Avwe.Hooks`): inputs, accepted as if they came from outside.
  defp resumed_by_hooks(state) do
    context = %{world: state.world, dir: state.dir, definition: state.definition}

    Enum.reduce(state.hooks, state, fn hook, acc ->
      if hooked?(hook, :on_resume, 2),
        do: Enum.reduce(hook.on_resume(acc.region, context), acc, &accept(&2, &1)),
        else: acc
    end)
  end

  defp journal(%{store: nil}, _step, _input), do: :ok

  defp journal(%{store: store}, step, input),
    do: Store.append(store, Store.submit_record(step, input))

  defp persist(%{store: nil}, _before, _steps, _dt, _events, _region), do: :ok

  defp persist(%{store: store} = state, before, steps, dt, events, region) do
    with :ok <- Store.append(store, Store.advance_record(before, steps, dt, events)) do
      if snapshot_due?(before.step, region.step, state.snapshot_every),
        do:
          Store.snapshot(store, region, keep: state.snapshot_keep, definition: state.definition),
        else: :ok
    end
  end

  # True when the advance crossed a multiple of `every`, however many steps it took.
  defp snapshot_due?(from, to, every), do: div(to, every) > div(from, every)

  defp publish(table, region) do
    :ets.insert(table, {:snapshot, Region.snapshot(region)})
  end

  # A step that produced events is told to every subscriber. One that
  # produced none is told only to those that asked to hear of every step
  # (`Avwe.subscribe/2`): a session that draws a scene follows the world step
  # by step, not event by event, and the rest are not woken for nothing.
  defp broadcast(world, events, view) do
    Registry.dispatch(Avwe.PubSub, {:events, world}, fn subscribers ->
      for {pid, every_step?} <- subscribers, events != [] or every_step? == true do
        send(pid, {:avwe_events, world, events, view})
      end
    end)
  end
end
