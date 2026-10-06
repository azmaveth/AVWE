defmodule Avwe.RegionServer do
  @moduledoc """
  Runs one `Avwe.Region` as a process.

  After every advance it publishes a snapshot to an ETS table it owns, so
  readers never block the tick and never call this process. Events go to
  subscribers registered with `Avwe.subscribe/1`, together with a view of the
  state they happened in (`Avwe.Region.view/1`). Intents queue in the region's
  inbox until the next step.

  With a `:store` dir the region persists itself through `Avwe.Store`: every
  intent is journaled as it is accepted, every advance is appended to the log
  before it is published, and a snapshot is written whenever an advance
  crosses a multiple of `:snapshot_every` steps (a multi-step advance that
  crosses one snapshots at the end of that advance). `:snapshot_keep` is how
  many of the newest snapshots to keep besides the first.

  A region that starts with saved state resumes from it; that is how a world
  restarts, and how the supervisor brings a crashed region back where it was.
  The saved state wins for state (seed, time, terrain, components, fields,
  env), but the systems come from the region the server was given: they are
  code, not state, and the rules may change while the world runs. The region
  it was given is otherwise ignored, with a warning for each setting of it
  (seed, climate, hearths, miracles, characters, the items they carry
  included) that differs from the saved world.

  A body still held when its world stopped is held by nobody once the world
  starts again (sessions end with their world and do not release it), so
  on starting the server releases every body whose holder has no live
  lease in this world: one `:release` intent each, submitted and journaled
  as a session's would be, so the routine takes the body at the next step
  and the next player is told what it did meanwhile.

  A log is only valid under the systems it was recorded with, and replay
  runs the systems of the snapshot it starts from. So when the systems
  change on a resume, the reconfigured region is snapshotted at once: the
  log from that point belongs to the new rules, and a crash before the next
  regular snapshot replays the gap under them, not the old ones.
  """

  use GenServer

  alias Avwe.{Intent, Region, Store}

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

  @doc "Queues an intent for the region's next step."
  @spec submit(term(), term(), Avwe.Intent.t()) :: :ok | {:error, :not_found}
  def submit(world, region_id, intent) do
    call(world, region_id, {:submit, intent})
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

    case open_store(Keyword.get(opts, :store), Keyword.fetch!(opts, :region), keep) do
      {:ok, store, region} ->
        table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
        {:ok, _owner} = Registry.register(Avwe.Registry, {:region, world, region.id}, table)
        :ets.insert(table, {:terrain, region.terrain})

        state =
          release_unheld(%{
            world: world,
            region: region,
            table: table,
            store: store,
            snapshot_every: Keyword.get(opts, :snapshot_every, @default_snapshot_every),
            snapshot_keep: keep
          })

        publish(table, state.region)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:store, reason}}
    end
  end

  @impl GenServer
  def handle_call({:submit, intent}, _from, state), do: {:reply, :ok, accept(state, intent)}

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
  defp open_store(nil, region, _keep), do: {:ok, nil, region}

  defp open_store(dir, region, keep) do
    with {:ok, store} <- Store.open(dir, region.id, owner: true),
         {:ok, region} <- resume(store, region, keep) do
      {:ok, store, region}
    end
  end

  defp resume(store, region, keep) do
    case Store.rebuild(store) do
      {:ok, saved} ->
        Logger.info(
          "Resumed region #{inspect(saved.id)} at step #{saved.step} from #{store.path}"
        )

        resumed = reconfigure(saved, region, store.dir)
        with :ok <- snapshot_if_rules_changed(store, saved, resumed, keep), do: {:ok, resumed}

      :none ->
        start_fresh(store, region, keep)

      {:error, {:unknown_snapshot, path, tag}} = error ->
        Logger.error(
          "Region #{inspect(region.id)}: no snapshot this build can read; #{path} is " <>
            "tagged #{inspect(tag)} and this build reads {:avwe_snapshot, 1}. " <>
            "Delete the world folder #{store.dir} to start over."
        )

        error

      {:error, _reason} = error ->
        error
    end
  end

  # Replay runs the systems of the snapshot it starts from, so a log written
  # under new systems must begin at a snapshot that carries them.
  defp snapshot_if_rules_changed(_store, %{systems: same}, %{systems: same}, _keep), do: :ok

  defp snapshot_if_rules_changed(store, _saved, resumed, keep),
    do: Store.snapshot(store, resumed, keep: keep)

  # A log with no snapshot to replay it onto can't be resumed and must not be
  # started over: the world fails to start instead.
  defp start_fresh(store, region, keep) do
    if Store.empty?(store),
      do: with(:ok <- Store.snapshot(store, region, keep: keep), do: {:ok, region}),
      else: {:error, :log_without_snapshot}
  end

  # Configuration beats the snapshot for code; the snapshot wins for state.
  # The settings the given region was built from (`Avwe.Worldgen`) are state
  # too, so each one that differs from the saved world is named and ignored.
  defp reconfigure(saved, given, dir) do
    for {setting, phrase, wanted, kept} <- ignored_settings(saved, given) do
      Logger.warning(
        "Region #{inspect(saved.id)}: ignoring :#{setting} #{inspect(wanted)}; " <>
          "the world's #{phrase} #{inspect(kept)}; delete #{dir} to start over"
      )
    end

    if given.systems != saved.systems do
      Logger.info(
        "Region #{inspect(saved.id)}: systems changed from #{inspect(saved.systems)} " <>
          "to #{inspect(given.systems)}"
      )
    end

    added = given.systems -- saved.systems
    Region.prepare(%{saved | systems: given.systems}, only: added)
  end

  # The settings of `given` that the saved world cannot take on, as
  # `{setting, "what is", wanted, kept}` for the warning.
  defp ignored_settings(saved, given) do
    lit = lit_hearths(saved)

    [
      {:seed, "seed is", & &1.seed},
      {:climate, "wind is", &Map.get(&1.env, :wind)},
      {:hearths, "hearths are", &hearths(&1, lit)},
      {:miracles, "miracles are", &miracles/1},
      {:characters, "characters are", &characters/1}
    ]
    |> Enum.map(fn {setting, phrase, declared} ->
      {setting, phrase, declared.(given), declared.(saved)}
    end)
    |> Enum.reject(fn {_setting, _phrase, wanted, kept} -> wanted == kept end)
  end

  # A hearth as declared: its power and the wood laid in it. A hearth that
  # has been lit has burned some of that wood, so for those (`lit`) the fuel
  # is state by now and only the power is compared. Standing miracles carry
  # a hearth too, but are declared as miracles.
  defp hearths(region, lit) do
    for id <- Region.with_components(region, [:hearth]),
        Region.get(region, id, :miracle) == nil,
        into: %{} do
      keys = if id in lit, do: [:power_w], else: [:fuel_kg, :power_w]
      {id, region |> Region.get(id, :hearth) |> Map.take(keys)}
    end
  end

  defp lit_hearths(region) do
    for id <- Region.with_components(region, [:hearth]),
        Region.get(region, id, :hearth).lit_at != nil,
        do: id
  end

  # A miracle as declared: everything but when it was applied.
  defp miracles(region) do
    for id <- Region.with_components(region, [:miracle]), into: %{} do
      {id, region |> Region.get(id, :miracle) |> Map.delete(:applied_at)}
    end
  end

  # A character as declared: the routine and norms of every body that has
  # any, and the ids of the items it carries (what is written in a notebook
  # is state, not declaration).
  defp characters(region) do
    carried =
      region
      |> Region.with_components([:item, :carried_by])
      |> Enum.group_by(&Region.get(region, &1, :carried_by))

    for id <- Region.with_components(region, [:body]),
        declared = Map.take(Region.entity(region, id), [:routine, :norms]),
        declared = put_carries(declared, carried[id]),
        declared != %{},
        into: %{},
        do: {id, declared}
  end

  defp put_carries(declared, nil), do: declared
  defp put_carries(declared, items), do: Map.put(declared, :carries, items)

  # Queues an intent for the next step and journals it.
  defp accept(state, intent) do
    region = Region.submit(state.region, intent)
    :ok = journal(state, region.step, region |> Region.pending() |> List.last())
    %{state | region: region}
  end

  # A body is held by a session's lease, and sessions end with their world
  # without releasing (`Avwe.Session`), so a world that starts again, or a
  # region that crashed after its world stopped, finds holders written on
  # bodies that nobody holds any more. Each of them is released at the next
  # step, by an intent submitted and journaled like a session's own, so
  # replay gives the same; the routine then takes the body. A body whose
  # holder is a live session of this world (a region that crashed and came
  # back while its sessions ran) is left alone.
  defp release_unheld(state) do
    world_pid = Avwe.World.whereis(state.world)
    pending = Region.pending(state.region)

    for body <- Region.with_components(state.region, [:control]),
        holder = holder_after(Region.get(state.region, body, :control).holder, pending, body),
        holder != nil,
        not leased?(state.world, world_pid, body),
        reduce: state do
      acc ->
        ref = "resume-release-#{System.unique_integer([:positive])}"
        accept(acc, Intent.new(body, :release, ref: ref, controller: holder))
    end
  end

  # Who will hold the body once the lease intents already waiting for the
  # next step (journaled before the world stopped) are applied, in order.
  defp holder_after(holder, pending, body) do
    Enum.reduce(pending, holder, fn
      %Intent{body: ^body, verb: :control, controller: controller}, _held -> controller
      %Intent{body: ^body, verb: :release}, _held -> nil
      _other, held -> held
    end)
  end

  defp leased?(world, world_pid, body) do
    match?(
      [{_session, {_controller, ^world_pid}}],
      Registry.lookup(Avwe.Registry, {:lease, world, body})
    )
  end

  defp journal(%{store: nil}, _step, _intent), do: :ok

  defp journal(%{store: store}, step, intent),
    do: Store.append(store, Store.submit_record(step, intent))

  defp persist(%{store: nil}, _before, _steps, _dt, _events, _region), do: :ok

  defp persist(%{store: store} = state, before, steps, dt, events, region) do
    with :ok <- Store.append(store, Store.advance_record(before, steps, dt, events)) do
      if snapshot_due?(before.step, region.step, state.snapshot_every),
        do: Store.snapshot(store, region, keep: state.snapshot_keep),
        else: :ok
    end
  end

  # True when the advance crossed a multiple of `every`, however many steps it took.
  defp snapshot_due?(from, to, every), do: div(to, every) > div(from, every)

  defp publish(table, region) do
    :ets.insert(table, {:snapshot, Region.snapshot(region)})
  end

  defp broadcast(_world, [], _view), do: :ok

  defp broadcast(world, events, view) do
    Registry.dispatch(Avwe.PubSub, {:events, world}, fn subscribers ->
      for {pid, _value} <- subscribers, do: send(pid, {:avwe_events, world, events, view})
    end)
  end
end
