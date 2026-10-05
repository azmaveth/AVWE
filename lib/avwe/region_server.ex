defmodule Avwe.RegionServer do
  @moduledoc """
  Runs one `Avwe.Region` as a process.

  After every advance it publishes a snapshot to an ETS table it owns, so
  readers never block the tick and never call this process. Events go to
  subscribers registered with `Avwe.subscribe/1`, together with a view of the
  state they happened in (`Avwe.Region.view/1`). Intents queue in the region's
  inbox until the next step.

  With a `:store` dir the region persists itself through `Avwe.Store`: every
  advance is appended to the log before it is published, and a snapshot is
  written every `:snapshot_every` steps. A region that starts with saved state
  resumes from it and ignores the region it was given; that is how a world
  restarts, and how the supervisor brings a crashed region back where it was.
  """

  use GenServer

  require Logger

  alias Avwe.{Region, Store}

  @default_snapshot_every 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

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

  @impl true
  def init(opts) do
    # So terminate/2 runs on supervisor shutdown and closes the store.
    Process.flag(:trap_exit, true)
    world = Keyword.fetch!(opts, :world)

    case open_store(Keyword.get(opts, :store), Keyword.fetch!(opts, :region)) do
      {:ok, store, region} ->
        table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
        {:ok, _owner} = Registry.register(Avwe.Registry, {:region, world, region.id}, table)
        :ets.insert(table, {:terrain, region.terrain})
        publish(table, region)

        {:ok,
         %{
           world: world,
           region: region,
           table: table,
           store: store,
           snapshot_every: Keyword.get(opts, :snapshot_every, @default_snapshot_every)
         }}

      {:error, reason} ->
        {:stop, {:store, reason}}
    end
  end

  @impl true
  def handle_call({:submit, intent}, _from, state) do
    {:reply, :ok, %{state | region: Region.submit(state.region, intent)}}
  end

  def handle_call({:advance, steps}, _from, state) do
    before = state.region
    {events, region} = before |> Region.advance(steps) |> Region.drain_events()

    :ok = persist(state, before, steps, events, region)
    publish(state.table, region)
    broadcast(state.world, events, Region.view(region))

    {:reply, {:ok, %{step: region.step, time: region.time}}, %{state | region: region}}
  end

  def handle_call(:state_hash, _from, state) do
    {:reply, {:ok, Region.state_hash(state.region)}, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, {:linked_process_exited, reason}, state}
  end

  @impl true
  def terminate(_reason, %{store: nil}), do: :ok
  def terminate(_reason, %{store: store}), do: Store.close(store)

  # Without a store the region starts as given. With one, saved state wins
  # over the given region, and a fresh store gets the given region as its
  # step-0 snapshot so the whole history can be replayed from it.
  defp open_store(nil, region), do: {:ok, nil, region}

  defp open_store(dir, region) do
    with {:ok, store} <- Store.open(dir, region.id),
         {:ok, region} <- resume(store, region) do
      {:ok, store, region}
    end
  end

  defp resume(store, region) do
    case Store.rebuild(store) do
      {:ok, saved} ->
        Logger.info(
          "Resumed region #{inspect(saved.id)} at step #{saved.step} from #{store.path}"
        )

        {:ok, saved}

      :none ->
        with :ok <- Store.snapshot(store, region), do: {:ok, region}

      {:error, _reason} = error ->
        error
    end
  end

  defp persist(%{store: nil}, _before, _steps, _events, _region), do: :ok

  defp persist(%{store: store, snapshot_every: every}, before, steps, events, region) do
    with :ok <- Store.append(store, Store.record(before, steps, events)) do
      if snapshot_due?(before.step, region.step, every),
        do: Store.snapshot(store, region),
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
