defmodule Avwe.World do
  @moduledoc """
  Supervises one running world: a `Avwe.RegionServer` per region, then the
  `Avwe.Clock` that steps them.

  With a `:store` dir each region keeps its log and snapshots under it, so a
  restarted region (after a crash, or when the world is started again) resumes
  where it was. Without one, a restarted region starts again from the state
  it was given at startup.
  """

  use Supervisor

  alias Avwe.{Clock, RegionServer}

  @doc """
  Options: `:id` (the world's id), `:regions` (a list of `Avwe.Region` structs),
  `:clock` (`:manual` or `{:live, interval_ms}`), `:info` (a map with the
  world's `:name` and `:tagline`, shown to people choosing a world, and what
  else `Avwe.start_world/2` tells of it: `:clock`, `:dt`, `:guests` and
  `:definition`), `:store` (a dir for the regions' logs and snapshots, or `nil`
  for no persistence), `:snapshot_every` (steps between snapshots),
  `:snapshot_keep` (how many of the newest snapshots to keep) and `:definition`
  (the hash of the world definition the regions were built from, or `nil`: it
  is recorded in every snapshot, and a saved world refuses another). See
  `Avwe.RegionServer`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    info = Keyword.get(opts, :info, %{name: to_string(id), tagline: nil})

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {Avwe.Registry, {:world, id}, info}}
    )
  end

  @doc "Every running world as `{id, info}`, sorted by id."
  @spec list() :: [{term(), map()}]
  def list do
    Avwe.Registry
    |> Registry.select([{{{:world, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  @doc "What a running world says of itself (`Avwe.worlds/0`), or `:error`."
  @spec info(term()) :: {:ok, map()} | :error
  def info(id) do
    case Registry.lookup(Avwe.Registry, {:world, id}) do
      [{_pid, info}] -> {:ok, info}
      [] -> :error
    end
  end

  @doc "The supervisor pid of a running world."
  @spec whereis(term()) :: pid() | nil
  def whereis(id), do: GenServer.whereis(via(id))

  defp via(id), do: {:via, Registry, {Avwe.Registry, {:world, id}}}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl Supervisor
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    regions = Keyword.fetch!(opts, :regions)

    persistence = Keyword.take(opts, [:store, :snapshot_every, :snapshot_keep, :definition])

    region_children =
      Enum.map(regions, &{RegionServer, [world: id, region: &1] ++ persistence})

    clock =
      {Clock,
       world: id,
       regions: regions |> Enum.map(& &1.id) |> Enum.sort(),
       mode: Keyword.get(opts, :clock, :manual)}

    Supervisor.init(region_children ++ [clock], strategy: :rest_for_one)
  end
end
