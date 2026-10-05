defmodule Avwe.RegionServer do
  @moduledoc """
  Runs one `Avwe.Region` as a process.

  After every advance it publishes a snapshot to an ETS table it owns, so
  readers never block the tick and never call this process. Events go to
  subscribers registered with `Avwe.subscribe/1`, together with a view of the
  state they happened in (`Avwe.Region.view/1`). Intents queue in the region's
  inbox until the next step.
  """

  use GenServer

  alias Avwe.Region

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
    case lookup(world, region_id) do
      {:ok, pid, _table} -> GenServer.call(pid, {:advance, steps}, :infinity)
      error -> error
    end
  end

  @doc "Queues an intent for the region's next step."
  @spec submit(term(), term(), Avwe.Intent.t()) :: :ok | {:error, :not_found}
  def submit(world, region_id, intent) do
    case lookup(world, region_id) do
      {:ok, pid, _table} -> GenServer.call(pid, {:submit, intent})
      error -> error
    end
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

  defp lookup(world, region_id) do
    case Registry.lookup(Avwe.Registry, {:region, world, region_id}) do
      [{pid, table}] -> {:ok, pid, table}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    world = Keyword.fetch!(opts, :world)
    region = Keyword.fetch!(opts, :region)

    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    {:ok, _owner} = Registry.register(Avwe.Registry, {:region, world, region.id}, table)
    :ets.insert(table, {:terrain, region.terrain})
    publish(table, region)

    {:ok, %{world: world, region: region, table: table}}
  end

  @impl true
  def handle_call({:submit, intent}, _from, state) do
    {:reply, :ok, %{state | region: Region.submit(state.region, intent)}}
  end

  def handle_call({:advance, steps}, _from, state) do
    {events, region} = state.region |> Region.advance(steps) |> Region.drain_events()

    publish(state.table, region)
    broadcast(state.world, events, Region.view(region))

    {:reply, {:ok, %{step: region.step, time: region.time}}, %{state | region: region}}
  end

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
