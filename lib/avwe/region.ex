defmodule Avwe.Region do
  @moduledoc """
  One square block of a world and everything in it.

  This is the pure core of the simulation. It never does I/O;
  `Avwe.RegionServer` runs it as a process.

  A region holds:

    * **components**, keyed by component name and then entity id. An entity is
      just an id that appears in one or more component maps.
    * **fields**, dense per-cell values such as temperature or water.
    * **env**, region-wide values such as light.
    * an **outbox** of events emitted since it was last drained.

  Build one with `new/1`, change it with the reducers, move it through time
  with `advance/3`, and read it with the converters.

  ## Determinism

  Advancing is deterministic: the same region advanced by the same steps always
  produces the same `state_hash/1`, whether it was advanced one step at a time
  or many at once. Entity queries return ids in sorted order, so systems never
  depend on map iteration order.
  """

  alias Avwe.{Event, Tick}

  @type entity_id :: String.t()
  @type component :: atom()

  @enforce_keys [:id, :seed]
  defstruct [
    :id,
    :seed,
    step: 0,
    time: 0,
    dt: 60,
    systems: [],
    components: %{},
    fields: %{},
    env: %{},
    outbox: []
  ]

  @type t :: %__MODULE__{
          id: term(),
          seed: integer(),
          step: non_neg_integer(),
          time: Avwe.Calendar.time(),
          dt: pos_integer(),
          systems: [module()],
          components: %{component() => %{entity_id() => term()}},
          fields: %{atom() => term()},
          env: %{atom() => term()},
          outbox: [Event.t()]
        }

  # Constructor

  @doc """
  Creates an empty region.

  Options: `:id` and `:seed` (required), `:time` (default 0), `:dt` (step length
  in world seconds, default 60) and `:systems` (run in order every step).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      seed: Keyword.fetch!(opts, :seed),
      time: Keyword.get(opts, :time, 0),
      dt: Keyword.get(opts, :dt, 60),
      systems: Keyword.get(opts, :systems, [])
    }
  end

  # Reducers

  @doc "Adds an entity, or merges components into an existing one."
  @spec put_entity(t(), entity_id(), %{component() => term()} | keyword()) :: t()
  def put_entity(%__MODULE__{} = region, id, components) do
    Enum.reduce(components, region, fn {name, value}, acc ->
      put_component(acc, id, name, value)
    end)
  end

  @doc "Sets one component on an entity."
  @spec put_component(t(), entity_id(), component(), term()) :: t()
  def put_component(%__MODULE__{components: components} = region, id, name, value) do
    by_id = components |> Map.get(name, %{}) |> Map.put(id, value)
    %{region | components: Map.put(components, name, by_id)}
  end

  @doc "Removes an entity and all its components."
  @spec delete_entity(t(), entity_id()) :: t()
  def delete_entity(%__MODULE__{components: components} = region, id) do
    %{
      region
      | components: Map.new(components, fn {name, by_id} -> {name, Map.delete(by_id, id)} end)
    }
  end

  @doc "Sets a region-wide environment value."
  @spec put_env(t(), atom(), term()) :: t()
  def put_env(%__MODULE__{env: env} = region, key, value) do
    %{region | env: Map.put(env, key, value)}
  end

  @doc """
  Advances the region by `steps` steps.

  Options: `:dt` overrides the region's step length for these steps. Events
  emitted along the way collect in the outbox; take them with
  `drain_events/1`.
  """
  @spec advance(t(), non_neg_integer(), keyword()) :: t()
  def advance(%__MODULE__{} = region, steps \\ 1, opts \\ [])
      when is_integer(steps) and steps >= 0 do
    dt = Keyword.get(opts, :dt, region.dt)
    Enum.reduce(List.duplicate(dt, steps), region, &step(&2, &1))
  end

  defp step(region, dt) do
    tick = %Tick{
      step: region.step,
      time: region.time,
      dt: dt,
      seed: region.seed,
      region: region.id
    }

    region.systems
    |> Enum.reduce(region, &run_system(&2, &1, tick))
    |> finish_step(tick)
  end

  defp run_system(region, system, tick) do
    {region, events} = system.run(region, tick)
    stamped = Enum.map(events, &stamp(&1, region.id, tick))
    %{region | outbox: Enum.reverse(stamped, region.outbox)}
  end

  defp stamp(%Event{} = event, region_id, tick) do
    %{event | region: region_id, time: event.time || Tick.end_time(tick)}
  end

  defp finish_step(region, tick) do
    %{region | step: tick.step + 1, time: Tick.end_time(tick)}
  end

  # Converters

  @doc "One component of an entity, or `nil`."
  @spec get(t(), entity_id(), component()) :: term()
  def get(%__MODULE__{components: components}, id, name) do
    components |> Map.get(name, %{}) |> Map.get(id)
  end

  @doc "All components of an entity, as a map. Empty if the entity doesn't exist."
  @spec entity(t(), entity_id()) :: %{component() => term()}
  def entity(%__MODULE__{components: components}, id) do
    for {name, by_id} <- components, Map.has_key?(by_id, id), into: %{}, do: {name, by_id[id]}
  end

  @doc "Ids of every entity that has all the given components, sorted."
  @spec with_components(t(), [component(), ...]) :: [entity_id()]
  def with_components(%__MODULE__{components: components}, [first | rest]) do
    others = Enum.map(rest, &Map.get(components, &1, %{}))

    components
    |> Map.get(first, %{})
    |> Map.keys()
    |> Enum.filter(fn id -> Enum.all?(others, &Map.has_key?(&1, id)) end)
    |> Enum.sort()
  end

  @doc "Takes the events emitted since the last drain, oldest first."
  @spec drain_events(t()) :: {[Event.t()], t()}
  def drain_events(%__MODULE__{outbox: outbox} = region) do
    {Enum.reverse(outbox), %{region | outbox: []}}
  end

  @doc """
  A hash of the region's state, ignoring the outbox. Two regions with the same
  hash are in the same state.
  """
  @spec state_hash(t()) :: String.t()
  def state_hash(%__MODULE__{} = region) do
    binary = :erlang.term_to_binary(%{region | outbox: []}, [:deterministic])
    :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
  end

  @doc "A read-only view of the region for perception and clients."
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = region) do
    Map.take(region, [:id, :step, :time, :components, :fields, :env])
  end
end
