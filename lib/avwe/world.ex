defmodule Avwe.World do
  @moduledoc """
  Supervises one running world: a `Avwe.RegionServer` per region, then the
  `Avwe.Clock` that steps them.

  Until persistence lands, a restarted region starts again from the state it
  was given at startup.
  """

  use Supervisor

  alias Avwe.{Clock, RegionServer}

  @doc """
  Options: `:id` (the world's id), `:regions` (a list of `Avwe.Region` structs)
  and `:clock` (`:manual` or `{:live, interval_ms}`).
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
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

    region_children = Enum.map(regions, &{RegionServer, world: id, region: &1})

    clock =
      {Clock,
       world: id,
       regions: regions |> Enum.map(& &1.id) |> Enum.sort(),
       mode: Keyword.get(opts, :clock, :manual)}

    Supervisor.init(region_children ++ [clock], strategy: :rest_for_one)
  end
end
