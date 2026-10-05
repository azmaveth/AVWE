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
  world's `:name` and `:tagline`, shown to people choosing a world), `:store`
  (a dir for the regions' logs and snapshots, or `nil` for no persistence)
  and `:snapshot_every` (steps between snapshots). See `Avwe.RegionServer`.
  """
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

  @doc "The supervisor pid of a running world."
  @spec whereis(term()) :: pid() | nil
  def whereis(id), do: GenServer.whereis(via(id))

  defp via(id), do: {:via, Registry, {Avwe.Registry, {:world, id}}}

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    regions = Keyword.fetch!(opts, :regions)

    persistence = Keyword.take(opts, [:store, :snapshot_every])

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
