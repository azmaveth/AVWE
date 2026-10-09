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
    * **terrain**, the static shape of the land, opaque to the simulation and
      owned by one rule, or `nil`.
    * an **inbox** of inputs waiting for the next step (`Avwe.Input`), and an
      **outbox** of events emitted since it was last drained.

  Build one with `new/1`, change it with the reducers, move it through time
  with `advance/3`, and read it with the converters.

  ## Determinism

  Advancing is deterministic: the same region advanced by the same steps always
  produces the same `state_hash/1`, whether it was advanced one step at a time
  or many at once. Entity queries return ids in sorted order, so systems never
  depend on map iteration order.
  """

  alias Avwe.{Event, Input, SystemTable, Tick}

  @type entity_id :: String.t()
  @type component :: atom()

  @typedoc """
  A system the region runs: its stable id (`Avwe.System`) and its options.
  `every: seconds` makes it run only in a step that reaches a multiple of that
  many seconds.
  """
  @type system :: {SystemTable.id(), keyword()}

  @enforce_keys [:id, :seed]
  defstruct [
    :id,
    :seed,
    :terrain,
    step: 0,
    time: 0,
    dt: 60,
    systems: [],
    components: %{},
    fields: %{},
    env: %{},
    inbox: [],
    next_seq: 0,
    outbox: []
  ]

  @type t :: %__MODULE__{
          id: term(),
          seed: integer(),
          terrain: term(),
          step: non_neg_integer(),
          time: Avwe.Calendar.time(),
          dt: pos_integer(),
          systems: [system()],
          components: %{component() => %{entity_id() => term()}},
          fields: %{atom() => term()},
          env: %{atom() => term()},
          inbox: [Input.t()],
          next_seq: non_neg_integer(),
          outbox: [Event.t()]
        }

  # Constructor

  @doc """
  Creates an empty region.

  Options: `:id` and `:seed` (required), `:time` (default 0), `:dt` (step length
  in world seconds, default 60) and `:systems` (run in order every step).
  Systems are given as modules, as ids, or as `{module_or_id, options}`
  (`systems/1`).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      seed: Keyword.fetch!(opts, :seed),
      time: Keyword.get(opts, :time, 0),
      dt: Keyword.get(opts, :dt, 60),
      systems: systems(Keyword.get(opts, :systems, []))
    }
  end

  @doc """
  The systems a region runs, as the region keeps them: `{id, options}`. A
  module is registered under its id (`Avwe.SystemTable.register/1`); an id
  must already be one some module runs, or this raises. What `new/1` and
  `put_systems/2` do to what they are given, and what a list that is already
  in this form comes through unchanged.
  """
  @spec systems([module() | String.t() | {module() | String.t(), keyword()}]) :: [system()]
  def systems(given) when is_list(given), do: Enum.map(given, &system/1)

  defp system({module_or_id, options}) when is_list(options),
    do: {system_id(module_or_id), options}

  defp system(module_or_id), do: {system_id(module_or_id), []}

  defp system_id(module) when is_atom(module), do: SystemTable.register(module)

  defp system_id(id) when is_binary(id) do
    case SystemTable.fetch(id) do
      {:ok, _module} -> id
      :error -> raise ArgumentError, SystemTable.unknown(id)
    end
  end

  @doc "Replaces the systems the region runs (`systems/1`)."
  @spec put_systems(t(), [module() | String.t() | {module() | String.t(), keyword()}]) :: t()
  def put_systems(%__MODULE__{} = region, given), do: %{region | systems: systems(given)}

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

  @doc "Removes one component from an entity."
  @spec delete_component(t(), entity_id(), component()) :: t()
  def delete_component(%__MODULE__{components: components} = region, id, name) do
    case components do
      %{^name => by_id} -> %{region | components: %{components | name => Map.delete(by_id, id)}}
      _no_component -> region
    end
  end

  @doc """
  Queues an input (`Avwe.Input`) for the next step and numbers it. Inputs are
  applied at the start of the step, sorted by `{order_key, seq}`.
  """
  @spec submit(t(), Input.t()) :: t()
  def submit(%__MODULE__{inbox: inbox, next_seq: seq} = region, input) do
    %{region | inbox: [Input.put_seq(input, seq) | inbox], next_seq: seq + 1}
  end

  @doc "Sets a region-wide environment value."
  @spec put_env(t(), atom(), term()) :: t()
  def put_env(%__MODULE__{env: env} = region, key, value) do
    %{region | env: Map.put(env, key, value)}
  end

  @doc """
  Lets each system set up state that depends on the starting time (see
  `c:Avwe.System.prepare/1`). Call once, after building the region and before
  the first step.

  Pass `only: systems` (system ids, or entries as `systems/1` gives them) to
  prepare just those (a region resumed from disk prepares only the systems
  added since it was saved).
  """
  @spec prepare(t(), keyword()) :: t()
  def prepare(%__MODULE__{systems: systems} = region, opts \\ []) do
    chosen = opts |> Keyword.get(:only, systems) |> Enum.map(&entry_id/1)

    systems
    |> Enum.map(&entry_id/1)
    |> Enum.filter(&(&1 in chosen))
    |> Enum.reduce(region, fn id, acc -> prepare_system(SystemTable.fetch!(id), acc) end)
  end

  defp prepare_system(module, region) do
    Code.ensure_loaded!(module)
    if function_exported?(module, :prepare, 1), do: module.prepare(region), else: region
  end

  defp entry_id({id, _options}), do: id
  defp entry_id(id), do: id

  @doc """
  Advances the region by `steps` steps.

  Options: `:dt` overrides the region's step length for these steps, and
  `:observe` is a function called after each system has run, with the system's
  id and the region before and after it (for tools that measure what a system
  changes; `Avwe.RuleCase`). Events emitted along the way collect in the outbox;
  take them with `drain_events/1`.
  """
  @spec advance(t(), non_neg_integer(), keyword()) :: t()
  def advance(%__MODULE__{} = region, steps \\ 1, opts \\ [])
      when is_integer(steps) and steps >= 0 do
    dt = Keyword.get(opts, :dt, region.dt)
    observe = Keyword.get(opts, :observe)
    Enum.reduce(List.duplicate(dt, steps), region, &step(&2, &1, observe))
  end

  # A step starts with an empty outbox, so `step_events/2` reads only its
  # own events, and puts the earlier ones back behind them when it ends:
  # that costs the step's own events, not the whole undrained outbox.
  defp step(%__MODULE__{outbox: earlier} = region, dt, observe) do
    tick = %Tick{
      step: region.step,
      time: region.time,
      dt: dt,
      seed: region.seed,
      region: region.id
    }

    stepped =
      %{region | outbox: []}
      |> apply_inputs(tick)
      |> run_systems(tick, observe)
      |> finish_step(tick)

    %{stepped | outbox: stepped.outbox ++ earlier}
  end

  defp apply_inputs(%__MODULE__{inbox: []} = region, _tick), do: region

  defp apply_inputs(%__MODULE__{inbox: inbox} = region, tick) do
    inbox
    |> Enum.sort_by(&{Input.order_key(&1), Input.seq(&1)})
    |> Enum.reduce(%{region | inbox: []}, fn input, acc ->
      {acc, events} = Input.handle(input, acc, tick)
      emit(acc, events, tick)
    end)
  end

  defp run_systems(region, tick, observe) do
    Enum.reduce(region.systems, region, fn {id, options}, acc ->
      case due(options, tick) do
        :skip -> acc
        system_tick -> run_system(acc, id, system_tick, tick, observe)
      end
    end)
  end

  # The system runs on its tick (which a period may have changed), and what
  # it emits is stamped by the step's.
  defp run_system(region, id, system_tick, tick, observe) do
    {ran, events} = SystemTable.fetch!(id).run(region, system_tick)
    if observe, do: observe.(id, region, ran)
    emit(ran, events, tick)
  end

  # A system with a period runs in the step that reaches a multiple of it,
  # whatever the step length (so the choice depends on time, never on counting
  # steps, and many steps at once are the same as one by one). It is told the
  # period it covers: a step as long as the period or longer is its own tick,
  # a shorter one becomes the last `every` seconds up to the step's end.
  defp due(options, tick) do
    case Keyword.get(options, :every) do
      nil ->
        tick

      every when tick.dt >= every ->
        tick

      every ->
        if Tick.crossed?(tick, every),
          do: %{tick | time: Tick.end_time(tick) - every, dt: every},
          else: :skip
    end
  end

  defp emit(region, events, tick) do
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

  @doc "The inputs waiting for the next step, in the order they were submitted."
  @spec pending(t()) :: [Input.t()]
  def pending(%__MODULE__{inbox: inbox}), do: Enum.reverse(inbox)

  @doc """
  The events emitted so far in the step `tick` describes, oldest first: the
  inputs' and those of the systems that ran before the caller. For a
  system that reacts to what happened earlier in the same step. A step
  runs on an outbox of its own (earlier events wait aside until it ends),
  so this is the same whether the region is advanced one step at a time
  and drained, as `Avwe.RegionServer` does, or many steps at once, as
  replay does, and it costs this step's events only.
  """
  @spec step_events(t(), Tick.t()) :: [Event.t()]
  def step_events(%__MODULE__{outbox: outbox}, %Tick{}), do: Enum.reverse(outbox)

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

  @doc """
  A read-only copy of the region's changing state for clients, including
  fields. Terrain is static and left out; `Avwe.RegionServer` publishes it once.
  """
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = region) do
    Map.take(region, [:id, :step, :time, :components, :fields, :env])
  end

  @doc """
  What perception needs: the snapshot without fields. Sent to subscribers with
  each step's events, so they perceive the events against the state the events
  happened in.
  """
  @spec view(t()) :: map()
  def view(%__MODULE__{} = region) do
    Map.take(region, [:id, :step, :time, :components, :env])
  end
end
