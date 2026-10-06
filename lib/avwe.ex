defmodule Avwe do
  @moduledoc """
  Azmaveth's Virtual World Engine: a headless world simulator.

  AVWE owns a world's rules and state. Clients connect and present it however
  they like. Worlds come from Quire. See `docs/DESIGN.md`.

  ## Quick start

  In `iex -S mix`, with Quire checked out next to this repo:

      {:ok, _pid} = Avwe.start_world(:ember_reach)
      Avwe.now(:ember_reach)          # "813 AR, day 220, 04:00"
      {:ok, mira} = Avwe.connect(:ember_reach, body: "mira-vale")
      Avwe.Session.act(mira, :go, target: "the-dry-bend")
      Avwe.step(:ember_reach, 10)     # ten world minutes
      flush()                         # {:avwe_percepts, _, [%Avwe.Percept{summary: "You arrive at The Dry Bend."}]}
  """

  alias Avwe.{Calendar, Clock, Quire, RegionServer}

  @default_region {0, 0}
  @default_systems [
    Avwe.Systems.Daylight,
    Avwe.Systems.Miracles,
    Avwe.Systems.Weather,
    Avwe.Systems.River,
    Avwe.Systems.Fire,
    Avwe.Systems.Heat,
    Avwe.Systems.Movement,
    Avwe.Systems.Waiting,
    Avwe.Systems.Discovery,
    Avwe.Systems.Autopilot,
    Avwe.Systems.Smoke
  ]

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
    * `:terrain`, `:hearths`, `:miracles`, `:climate` and `:characters` -
      AVWE's own settings for the world. See `Avwe.Worldgen`.
    * `:data_dir` - where worlds keep their logs and snapshots; this world's
      go under `<data_dir>/<id>`. Default: `config :avwe, :data_dir`. `nil`
      means no persistence. A world whose state is already there resumes
      from it: `:start`, `:seed`, `:terrain`, `:hearths`, `:miracles`,
      `:climate` and `:characters` are ignored (with a warning naming each
      of `:seed`, `:climate`, `:hearths`, `:miracles` and `:characters` that
      differs from the saved world), but `:systems` is applied, since the
      rules are code, not state. Replaying a log is only valid under the systems it was recorded
      with; after changing them, the region is snapshotted at once so the
      log from that point on belongs to the new rules.
    * `:snapshot_every` - steps between snapshots. A snapshot is written at
      the end of any advance that crosses a multiple of this; a multi-step
      advance that crosses one snapshots at the end of that advance, not at
      the multiple. Default: 1000.
    * `:snapshot_keep` - how many of the newest snapshots to keep besides the
      first one, which is always kept. Default: 5.
  """
  @spec start_world(atom(), keyword()) :: DynamicSupervisor.on_start_child() | {:error, term()}
  def start_world(id, opts \\ []) do
    opts = :avwe |> Application.get_env(:worlds, []) |> Keyword.get(id, []) |> Keyword.merge(opts)

    with {:ok, path} <- quire_path(opts),
         {:ok, quire_world} <- Quire.load(path) do
      region =
        Avwe.Worldgen.region(quire_world,
          id: @default_region,
          seed: Keyword.get_lazy(opts, :seed, fn -> :erlang.phash2(id) end),
          time: start_time(Keyword.get(opts, :start, 0)),
          systems: Keyword.get(opts, :systems, @default_systems),
          terrain: Keyword.get(opts, :terrain),
          hearths: Keyword.get(opts, :hearths, []),
          miracles: Keyword.get(opts, :miracles, []),
          climate: Keyword.get(opts, :climate),
          characters: Keyword.get(opts, :characters, [])
        )

      DynamicSupervisor.start_child(
        Avwe.Worlds,
        {Avwe.World,
         id: id,
         regions: [region],
         clock: Keyword.get(opts, :clock, :manual),
         info: %{name: quire_world.name, tagline: quire_world.tagline},
         store: store_dir(id, Keyword.get(opts, :data_dir, Application.get_env(:avwe, :data_dir))),
         snapshot_every: Keyword.get(opts, :snapshot_every, 1_000),
         snapshot_keep: Keyword.get(opts, :snapshot_keep, 5)}
      )
    end
  end

  defp store_dir(_id, nil), do: nil
  defp store_dir(id, data_dir), do: data_dir |> Path.expand() |> Path.join(to_string(id))

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
  `{:avwe_events, world, [%Avwe.Event{}], view}`, where `view` is the region's
  state just after the events (`Avwe.Region.view/1`).
  """
  @spec subscribe(atom()) :: {:ok, pid()} | {:error, term()}
  def subscribe(world), do: Registry.register(Avwe.PubSub, {:events, world}, nil)

  @doc "Every running world as `{id, %{name: name, tagline: tagline}}`."
  @spec worlds() :: [{atom(), map()}]
  def worlds, do: Avwe.World.list()

  @doc """
  The bodies in a world that a controller could take, with whether each is
  already `taken` (a session holds its lease) and who its `controller` is in
  the simulation: the holder written on the body's `:control` component, or
  `:autopilot` when nobody holds it (a taken body whose session has gone
  idle is autopilot's until the session acts again).
  """
  @spec bodies(atom()) :: {:ok, [map()]} | {:error, :not_found}
  def bodies(world) do
    with {:ok, snapshot} <- snapshot(world) do
      repr = Map.get(snapshot.components, :repr, %{})
      control = Map.get(snapshot.components, :control, %{})

      bodies =
        for id <- snapshot.components |> Map.get(:body, %{}) |> Map.keys() |> Enum.sort() do
          %{
            id: id,
            name: get_in(repr, [id, :name]) || id,
            description: get_in(repr, [id, :description]),
            taken: Registry.lookup(Avwe.Registry, {:lease, world, id}) != [],
            controller: get_in(control, [id, :holder]) || :autopilot
          }
        end

      {:ok, bodies}
    end
  end

  @doc """
  Connects a controller to a world and returns its `Avwe.Session`.

  Options:

    * `:body` - the body to control. Leave it out to watch as a spectator.
    * `:sink` - the process that receives percepts. Default: the caller.
    * `:controller` - `:human` (default), `:mcp` or `:arbor`; anything else
      fails with `:invalid_controller`.
    * `:idle_after` - real milliseconds without a call on the session
      (`Avwe.Session.act/3` or `Avwe.Session.look/1`) after which it yields
      the body to autopilot until its next act. Default: ten minutes.

  Fails with `:no_such_world`, `:no_such_body`, `:body_taken` or
  `:invalid_controller`.
  """
  @spec connect(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(world, opts \\ []) do
    opts = opts |> Keyword.put(:world, world) |> Keyword.put_new(:sink, self())
    DynamicSupervisor.start_child(Avwe.Sessions, {Avwe.Session, opts})
  end

  defp quire_path(opts) do
    case Keyword.fetch(opts, :quire) do
      {:ok, path} -> {:ok, Path.expand(path, Application.get_env(:avwe, :quire_root, "."))}
      :error -> {:error, :no_quire_path}
    end
  end

  defp start_time({year, opts}), do: Calendar.at(year, opts)
  defp start_time(time) when is_integer(time), do: time
end
