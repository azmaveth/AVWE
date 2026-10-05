defmodule Avwe do
  @moduledoc """
  Azmaveth's Virtual World Engine: a headless world simulator.

  AVWE owns a world's rules and state. Clients connect and present it however
  they like. Worlds come from Quire. See `docs/DESIGN.md`.

  ## Quick start

  In `iex -S mix`, with Quire checked out next to this repo:

      {:ok, _pid} = Avwe.start_world(:ember_reach)
      Avwe.now(:ember_reach)          # "813 AR, day 220, 04:00"
      Avwe.subscribe(:ember_reach)
      Avwe.step(:ember_reach, 120)    # two world hours
      flush()                         # {:avwe_events, :ember_reach, [%Avwe.Event{type: :sunrise}]}
  """

  alias Avwe.{Calendar, Clock, Quire, RegionServer}

  @default_region {0, 0}
  @default_systems [Avwe.Systems.Daylight]

  @doc """
  Loads a world from Quire and starts it.

  Options are read from `config :avwe, :worlds` under `id`, then overridden by
  `opts`:

    * `:quire` - the Quire world folder. A relative path is resolved against
      `config :avwe, :quire_root`.
    * `:start` - world time to start at, as an integer or `{year, opts}` for
      `Avwe.Calendar.at/2`. Default: the start of 0 AR.
    * `:seed` - world seed. Default: derived from `id`.
    * `:clock` - `:manual` (default) or `{:live, interval_ms}`.
    * `:systems` - systems to run, in order. Default: `#{inspect(@default_systems)}`.
  """
  @spec start_world(atom(), keyword()) :: DynamicSupervisor.on_start_child() | {:error, term()}
  def start_world(id, opts \\ []) do
    opts = :avwe |> Application.get_env(:worlds, []) |> Keyword.get(id, []) |> Keyword.merge(opts)

    with {:ok, path} <- quire_path(opts),
         {:ok, quire_world} <- Quire.load(path) do
      region =
        Quire.Seed.region(quire_world,
          id: @default_region,
          seed: Keyword.get_lazy(opts, :seed, fn -> :erlang.phash2(id) end),
          time: start_time(Keyword.get(opts, :start, 0)),
          systems: Keyword.get(opts, :systems, @default_systems)
        )

      DynamicSupervisor.start_child(
        Avwe.Worlds,
        {Avwe.World, id: id, regions: [region], clock: Keyword.get(opts, :clock, :manual)}
      )
    end
  end

  @doc "Stops a running world."
  @spec stop_world(atom()) :: :ok | {:error, :not_found}
  def stop_world(id) do
    case Avwe.World.whereis(id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Avwe.Worlds, pid)
    end
  end

  @doc "Advances a world by `ticks` ticks right now, whatever its clock mode."
  @spec step(atom(), pos_integer()) :: {:ok, %{step: non_neg_integer(), time: integer()}}
  def step(world, ticks \\ 1), do: Clock.step(world, ticks)

  @doc "The latest snapshot of a region. Never blocks the simulation."
  @spec snapshot(atom(), term()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(world, region \\ @default_region), do: RegionServer.snapshot(world, region)

  @doc "The world's current time, formatted for people."
  @spec now(atom()) :: String.t() | {:error, :not_found}
  def now(world) do
    with {:ok, snapshot} <- snapshot(world), do: Calendar.format(snapshot.time)
  end

  @doc """
  Subscribes the calling process to a world's events. They arrive as
  `{:avwe_events, world, [%Avwe.Event{}]}`.
  """
  @spec subscribe(atom()) :: {:ok, pid()} | {:error, term()}
  def subscribe(world), do: Registry.register(Avwe.PubSub, {:events, world}, nil)

  defp quire_path(opts) do
    case Keyword.fetch(opts, :quire) do
      {:ok, path} -> {:ok, Path.expand(path, Application.get_env(:avwe, :quire_root, "."))}
      :error -> {:error, :no_quire_path}
    end
  end

  defp start_time({year, opts}), do: Calendar.at(year, opts)
  defp start_time(time) when is_integer(time), do: time
end
