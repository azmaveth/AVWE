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

  A program that plays a body (the MCP adapter, Arbor) uses `Avwe.Mind`,
  which holds the session, runs plans and waits on world time:

      {:ok, mind} = Avwe.Mind.start(:ember_reach, "mira-vale", controller: :mcp)
      {:ok, look} = Avwe.Mind.look(mind)        # look.away: "While you were away"
      {:ok, %{status: :done}} = Avwe.Mind.act(mind, [{:go, target: "the-dry-bend"}, {:write, params: %{text: "Dry."}}])
  """

  alias Avwe.{Calendar, Clock, GroundCache, Quire, RegionServer, Terrain}

  require Logger

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
    Avwe.Systems.Smoke,
    Avwe.Systems.Memory
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
    * `:guests` - `[arrival: place_id, max: n]`: the world takes guests
      (`Avwe.Guests`), who arrive at that place, `n` of them at most. Without
      it the world takes none. It is how the world is run, not what is saved
      of it: a world that resumes from its saved state takes the guests it is
      started to take, and keeps the ones it has.
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
      warn_unplaced(id, Quire.Seed.unplaced(quire_world))

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
         info: %{
           name: quire_world.name,
           tagline: quire_world.tagline,
           clock: Keyword.get(opts, :clock, :manual),
           dt: region.dt,
           guests: guests!(region, Keyword.get(opts, :guests))
         },
         store: store_dir(id, Keyword.get(opts, :data_dir, Application.get_env(:avwe, :data_dir))),
         snapshot_every: Keyword.get(opts, :snapshot_every, 1_000),
         snapshot_keep: Keyword.get(opts, :snapshot_keep, 5)}
      )
    end
  end

  # A character whose home is not a pin on the map gets a body that is nowhere
  # (`Avwe.Quire.Seed`), and nobody can play it. Whoever runs the world, and
  # whoever writes its canon, should hear of it.
  defp warn_unplaced(_world, []), do: :ok

  defp warn_unplaced(world, unplaced) do
    count = length(unplaced)
    noun = if count == 1, do: "1 character is", else: "#{count} characters are"
    names = Enum.map_join(unplaced, ", ", &unplaced_name/1)

    Logger.warning(
      "#{world}: #{noun} not placed, so nobody can play them yet: #{names}. " <>
        "A character is placed at its home when the home is a pin on the map."
    )
  end

  defp unplaced_name(%{name: name, home: nil}), do: "#{name} (no home)"
  defp unplaced_name(%{name: name, home: home}), do: "#{name} (home: #{home})"

  # The settings guests arrive under, checked here where a bad one is easiest
  # to explain, as a bad hearth is: the place must be a place of the world.
  defp guests!(_region, nil), do: nil

  defp guests!(region, settings) do
    if not Keyword.keyword?(settings),
      do: raise(ArgumentError, "guests must be a keyword list, got #{inspect(settings)}")

    arrival = settings[:arrival]
    max = settings[:max]

    cond do
      not is_binary(arrival) or Avwe.Region.get(region, arrival, :place) == nil ->
        raise ArgumentError, "guests: arrival #{inspect(arrival)} is not a place of the world"

      not (is_integer(max) and max > 0) ->
        raise ArgumentError, "guests: max must be a positive integer, got #{inspect(max)}"

      true ->
        %{arrival: arrival, max: max}
    end
  end

  defp store_dir(_id, nil), do: nil
  defp store_dir(id, data_dir), do: data_dir |> Path.expand() |> Path.join(to_string(id))

  @doc """
  Builds the ground of a world's terrain in the background, if it has any and
  it is not kept yet (`Avwe.GroundCache`): the map a body's scene reads, and the
  world ground a spectator's page is given. So the first page to ask for a
  scene finds them ready and does not draw its first scene bare. It takes about
  a second for the Ember Reach, and returns at once. A world that is not
  running, or has no terrain, has nothing to build.
  """
  @spec warm_ground(atom()) :: :ok
  def warm_ground(world) do
    with {:ok, %{terrain: %Terrain{} = terrain}} <- snapshot(world),
         false <- GroundCache.world_cached?(terrain) do
      {:ok, _task} = Task.start(fn -> GroundCache.world(terrain) end)
    end

    :ok
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
  `{:avwe_events, world, [%Avwe.Event{}], view}`, where `view` is the region's
  state just after the events (`Avwe.Region.view/1`).

  A step that produced no events sends nothing, unless the subscriber asked
  for `steps: true`: then it hears of every step, with an empty list of events
  when there were none. A client that draws what a body sees needs that, since
  a body walks, and the light changes, between events.
  """
  @spec subscribe(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(world, opts \\ []),
    do: Registry.register(Avwe.PubSub, {:events, world}, Keyword.get(opts, :steps, false))

  @doc """
  Every running world as `{id, info}`: its `name` and `tagline`, and how
  its time passes, its `clock` (`:manual` or `{:live, interval_ms}`) and
  `dt`, the world seconds of each step, and the `guests` it takes, `nil` or
  `%{arrival: place, max: n}`.
  """
  @spec worlds() :: [{atom(), map()}]
  def worlds, do: Avwe.World.list()

  @doc """
  The bodies in a world that a controller could take, with whether each is
  already `taken` (a session holds its lease), who its `controller` is in
  the simulation: the holder written on the body's `:control` component, or
  `:autopilot` when nobody holds it (a taken body whose session has gone
  idle is autopilot's until the session acts again), and whether it is a
  `guest` (`Avwe.Guests`).

  A body that is nowhere, because its character's home is not on the map
  (`Avwe.Quire.Seed.unplaced/1`), cannot be taken and is not listed; see
  `elsewhere/1`.
  """
  @spec bodies(atom()) :: {:ok, [map()]} | {:error, :not_found}
  def bodies(world) do
    with {:ok, snapshot} <- snapshot(world) do
      repr = Map.get(snapshot.components, :repr, %{})
      control = Map.get(snapshot.components, :control, %{})
      guests = Map.get(snapshot.components, :guest, %{})

      bodies =
        for id <- body_ids(snapshot), placed?(snapshot, id) do
          %{
            id: id,
            name: get_in(repr, [id, :name]) || id,
            description: get_in(repr, [id, :description]),
            taken: Registry.lookup(Avwe.Registry, {:lease, world, id}) != [],
            controller: get_in(control, [id, :holder]) || :autopilot,
            guest: Map.has_key?(guests, id)
          }
        end

      {:ok, bodies}
    end
  end

  @doc """
  The characters of a world who are nowhere, as `%{id, name, description}`:
  their home is not a pin on the map (`Avwe.Quire.Seed.unplaced/1`), so their
  bodies have no position and nobody can play them yet. They are in the world's
  state and in canon, and `Avwe.connect/2` refuses them with `:elsewhere`.
  """
  @spec elsewhere(atom()) :: {:ok, [map()]} | {:error, :not_found}
  def elsewhere(world) do
    with {:ok, snapshot} <- snapshot(world) do
      repr = Map.get(snapshot.components, :repr, %{})

      away =
        for id <- body_ids(snapshot), not placed?(snapshot, id) do
          %{
            id: id,
            name: get_in(repr, [id, :name]) || id,
            description: get_in(repr, [id, :description])
          }
        end

      {:ok, away}
    end
  end

  defp body_ids(snapshot),
    do: snapshot.components |> Map.get(:body, %{}) |> Map.keys() |> Enum.sort()

  defp placed?(snapshot, id),
    do: snapshot.components |> Map.get(:position, %{}) |> Map.has_key?(id)

  @doc """
  Connects a controller to a world and returns its `Avwe.Session`.

  Options:

    * `:body` - the body to control. Leave it out to watch as a spectator.
    * `:guest` - `[name: ..., backstory: ...]` instead of a body: arrive in the
      world as a guest of your own making (`Avwe.Guests`), if the world takes
      guests (`:guests` of `start_world/2`). The body exists after the world's
      next step; `Avwe.Session.await_arrival/2` waits for it, and
      `Avwe.Session.look/1` answers `{:error, :arriving}` until then.
    * `:sink` - the process that receives percepts. Default: the caller.
    * `:controller` - `:human` (default), `:mcp` or `:arbor`; anything else
      fails with `:invalid_controller`.
    * `:idle_after` - real milliseconds without a call on the session
      (`Avwe.Session.act/3` or `Avwe.Session.look/1`) after which it yields
      the body to autopilot until its next act. Default: ten minutes.
    * `:scenes` - `true` for a client that draws: it asks for the first scene
      with `Avwe.Session.scene/1`, and is sent each one that follows as
      `{:avwe_scene, session, scene}`. A body's scene is what it sees
      (`Avwe.Scene`); a spectator's, with no `:body`, is the whole valley and its
      fields (`Avwe.WorldScene`), and its ground, which never changes, is
      `Avwe.Session.ground/1`. Default: `false`.

  Fails with `:no_such_world`, `:no_such_body`, `:elsewhere` (the body is
  nowhere: its character's home is not on the map; see `elsewhere/1`),
  `:body_taken` or `:invalid_controller`; and for a guest with `:body_and_guest`, `:no_guests`,
  `:invalid_name`, `:invalid_backstory`, `:name_taken` (the name is the name or
  id of something in the world, or of a guest who is there or arriving) or
  `:full`.
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
