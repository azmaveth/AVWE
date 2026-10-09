defmodule Avwe.Test.Golden do
  @moduledoc """
  The golden journal: runs of the Ember Reach, recorded once, that every later
  change must reproduce (`docs/engine-spec.md`, E1). A scenario is a region, a
  number of steps and a script of intents submitted before given steps, as a
  controller would submit them. Running one records, for every step, the events
  the systems emitted; the percepts a spectator, Mira and a guest are told of
  them; and, every so often, each body's look (and its words) and a digest of
  the whole state.

  A change that is meant to leave the world as it was must leave all of that as
  it was. Floats are rounded to #{6} significant digits before anything is
  compared, so the record does not depend on the last bit of a C library's `exp`
  (macOS and Linux differ there: five decimals was too fine for the heat field's
  large values, and the states of a run on Linux did not match), and `systems`
  is left out of the state, since later slices change how a region names its
  systems. A digest says that something changed;
  the full normalised streams, kept beside the digests, say what and where.

  Record with `MIX_ENV=test mix run -e 'Avwe.Test.Golden.record!()'`, and only
  on code whose behaviour is the one to keep.
  """

  alias Avwe.{Guests, Intent, Perception, Prose, Region}
  alias Avwe.Test.Ember

  @dir Path.expand("../fixtures/golden", __DIR__)
  @digests Path.join(@dir, "ember_reach.digests")
  @mira "mira-vale"
  @tomas "Tomas Reed"
  @look_every 180
  @state_every 360
  @digits 6

  @doc "The scenarios, in the order they are recorded and checked."
  @spec scenarios() :: [atom()]
  def scenarios, do: [:ember_813, :ember_812]

  @doc """
  The scenario called `name`.

  `:ember_813` is Mira under a controller on the morning of 813 AR, day 220: she
  lights the town hearth, speaks and writes, walks the banks, follows the
  channel, rests, says something at every volume, and is let go of for her
  routine to take; a guest arrives meanwhile. Two world days.

  `:ember_812` is the Ember Reach with nobody at the controls, from the
  afternoon before the river's source fails (812 AR, day 199) to three days
  after: the miracle, the channel running dry reach by reach, the silt cooling,
  the hearths, the smoke, and Mira's routine.
  """
  @spec scenario(atom()) :: map()
  def scenario(:ember_813) do
    %{
      name: :ember_813,
      region: Ember.region({813, day: 220, hour: 4}),
      steps: 2_880,
      watchers: [nil, @mira, "guest-tomas-reed"],
      script: %{
        0 => [{@mira, :control, [controller: :human]}],
        1 => [{@mira, :kindle, []}],
        20 => [
          {@mira, :say, [params: %{text: "The hearth is lit.", volume: :talk}]},
          {@mira, :write, [params: %{text: "Lit the town hearth before dawn."}]}
        ],
        30 => [arrival()],
        60 => [{@mira, :douse, []}],
        61 => [{@mira, :go, [target: "the-dry-bend"]}],
        100 => [{@mira, :follow, [params: %{direction: :upstream}]}],
        160 => [{@mira, :stop, []}],
        170 => [{@mira, :walk, [params: %{direction: "south", distance_m: 200}]}],
        200 => [{@mira, :wait, [params: %{for: 3_600}]}],
        300 => [{@mira, :read, [params: %{last: 5}]}],
        301 => [{@mira, :go, [target: "ashwarden-lodge"]}],
        500 => [
          {@mira, :say, [params: %{text: "Is anyone here?", volume: :whisper}]},
          {@mira, :say, [params: %{text: "Warm!", volume: :shout}]}
        ],
        520 => [{@mira, :wait, [params: %{until: :dusk}]}],
        900 => [{@mira, :kindle, [target: "lodge-hearth"]}],
        1_000 => [{@mira, :release, []}]
      }
    }
  end

  def scenario(:ember_812) do
    %{
      name: :ember_812,
      region: Ember.region({812, day: 199, hour: 14}),
      steps: 4_320,
      watchers: [nil, @mira],
      script: %{}
    }
  end

  defp arrival do
    {:ok, offer} = Guests.offer(@tomas, "A salvage diver from Willow Docks.")

    params = %{
      name: offer.name,
      backstory: offer.backstory,
      arrival: "ember-reach",
      max: 8
    }

    {offer.id, :arrive, [controller: :mcp, params: params]}
  end

  @doc """
  Runs a scenario and records it: the normalised events, percepts and looks, in
  order (`streams`), and the digests that stand for them (`digests`).
  """
  @spec run(atom() | map()) :: %{streams: map(), digests: map()}
  def run(scenario) when is_atom(scenario), do: run(scenario(scenario))

  def run(%{region: region, steps: steps} = scenario) do
    start = %{
      region: region,
      events: [],
      percepts: Map.new(scenario.watchers, &{&1, []}),
      looks: [],
      states: [],
      refs: 0
    }

    final =
      Enum.reduce(0..(steps - 1), start, fn step, acc ->
        acc |> submit(scenario, step) |> advance(scenario, step)
      end)

    streams = %{
      events: Enum.reverse(final.events),
      percepts: Map.new(final.percepts, fn {body, list} -> {body, Enum.reverse(list)} end),
      looks: Enum.reverse(final.looks)
    }

    %{streams: streams, digests: digests(streams, Enum.reverse(final.states), steps)}
  end

  defp submit(acc, scenario, step) do
    scenario.script
    |> Map.get(step, [])
    |> Enum.reduce(acc, fn {body, verb, opts}, acc ->
      refs = acc.refs + 1
      intent = Intent.new(body, verb, [ref: "golden-#{refs}"] ++ opts)
      %{acc | region: Region.submit(acc.region, intent), refs: refs}
    end)
  end

  defp advance(acc, scenario, step) do
    region = Region.advance(acc.region, 1)
    {events, region} = Region.drain_events(region)
    view = region |> Region.view() |> Map.put(:terrain, region.terrain)
    snapshot = region |> Region.snapshot() |> Map.put(:terrain, region.terrain)

    acc = %{acc | region: region}
    acc = %{acc | events: Enum.reverse(Enum.map(events, &normalize/1), acc.events)}

    acc =
      Enum.reduce(scenario.watchers, acc, fn watcher, acc ->
        told = told(view, watcher, events, step)
        %{acc | percepts: Map.update!(acc.percepts, watcher, &Enum.reverse(told, &1))}
      end)

    acc = if rem(step + 1, @look_every) == 0, do: looks(acc, scenario, snapshot, step), else: acc
    if rem(step + 1, @state_every) == 0, do: state(acc, step), else: acc
  end

  # What a body is told of a step's events. A guest hears nothing until it is made.
  defp told(view, watcher, events, step) do
    if here?(view, watcher) do
      for percept <- Perception.percepts(view, watcher, events), do: {step, normalize(percept)}
    else
      []
    end
  end

  defp looks(acc, scenario, snapshot, step) do
    taken =
      for watcher <- scenario.watchers, here?(snapshot, watcher) do
        look = Perception.look(snapshot, watcher)
        {step, watcher, normalize(look), Prose.look(look)}
      end

    %{acc | looks: Enum.reverse(taken, acc.looks)}
  end

  defp here?(_view, nil), do: true
  defp here?(view, body), do: view.components |> Map.get(:position, %{}) |> Map.has_key?(body)

  defp state(acc, step) do
    digest = acc.region |> Map.put(:systems, []) |> Map.put(:outbox, []) |> digest()
    %{acc | states: [{step + 1, digest} | acc.states]}
  end

  defp digests(streams, states, steps) do
    %{
      steps: steps,
      events: summary(streams.events),
      percepts: Map.new(streams.percepts, fn {body, list} -> {body, summary(list)} end),
      looks: summary(streams.looks),
      states: states
    }
  end

  defp summary(list), do: %{count: length(list), digest: digest(list)}

  @doc "A hex digest of any term, after `normalize/1`."
  @spec digest(term()) :: String.t()
  def digest(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(normalize(term), [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  A term with structs as maps that remember their module, sets as sorted lists,
  maps in key order, and floats rounded to #{@digits} significant digits (zero
  without a sign), so that two runs compare equal when nothing but the last bits
  of a float differ. The rounding is Erlang's own float formatting, which does
  not use the C library.
  """
  @spec normalize(term()) :: term()
  def normalize(%MapSet{} = set), do: {:set, set |> Enum.map(&normalize/1) |> Enum.sort()}

  def normalize(%module{} = struct),
    do: struct |> Map.from_struct() |> Map.put(:__module__, module) |> normalize()

  def normalize(map) when is_map(map) do
    pairs = Enum.map(map, fn {key, value} -> {normalize(key), normalize(value)} end)
    {:map, Enum.sort(pairs)}
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  def normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1) |> List.to_tuple()

  def normalize(float) when is_float(float) and float == 0.0, do: 0.0

  def normalize(float) when is_float(float) do
    float |> :erlang.float_to_binary(scientific: @digits - 1) |> :erlang.binary_to_float()
  end

  def normalize(other), do: other

  # Recording and checking

  @doc "Records every scenario: the digests, and the streams beside them."
  @spec record!() :: :ok
  def record! do
    File.mkdir_p!(@dir)

    digests =
      Map.new(scenarios(), fn name ->
        %{streams: streams, digests: digests} = run(name)
        binary = :erlang.term_to_binary(streams, [:compressed, :deterministic])
        File.write!(stream_path(name), binary)
        IO.puts("recorded #{name}: #{digests.events.count} events, #{digests.looks.count} looks")
        {name, digests}
      end)

    header = "# Recorded by Avwe.Test.Golden.record!/0; see its moduledoc.\n"
    File.write!(@digests, header <> inspect(digests, pretty: true, limit: :infinity) <> "\n")
  end

  @doc "The recorded digests of a scenario."
  @spec recorded(atom()) :: map()
  def recorded(name) do
    {digests, _binding} = Code.eval_file(@digests)
    Map.fetch!(digests, name)
  end

  defp recorded_streams(name),
    do: name |> stream_path() |> File.read!() |> :erlang.binary_to_term()

  defp stream_path(name), do: Path.join(@dir, "#{name}.term.gz")

  @doc """
  What differs between the recorded run of `name` and a new one, in words: a
  list that is empty when they agree. Where a stream differs it names the first
  place, with both sides.
  """
  @spec differences(atom(), %{streams: map(), digests: map()}) :: [String.t()]
  def differences(name, %{streams: streams, digests: actual}) do
    recorded = recorded(name)

    checks =
      [{:events, recorded.events, actual.events}] ++
        for(
          {body, summary} <- recorded.percepts,
          do: {{:percepts, body}, summary, actual.percepts[body]}
        ) ++
        [{:looks, recorded.looks, actual.looks}, {:states, recorded.states, actual.states}]

    for {what, was, now} <- checks, was != now do
      "#{inspect(what)} differ: #{describe(what, was, now)}#{where(name, streams, what)}"
    end
  end

  defp describe(:states, was, now) do
    case Enum.zip(was, now) |> Enum.find(fn {a, b} -> a != b end) do
      nil -> "recorded #{length(was)} checkpoints, now #{length(now)}."
      {{step, _a}, _b} -> "the state first differs at step #{step}."
    end
  end

  defp describe(_what, %{count: was}, %{count: now}), do: "recorded #{was} items, now #{now}."
  defp describe(_what, was, now), do: "recorded #{inspect(was)}, now #{inspect(now)}."

  defp where(_name, _streams, :states), do: ""

  defp where(name, streams, what) do
    {old, new} = {pick(recorded_streams(name), what), pick(streams, what)}

    case old |> Enum.zip(new) |> Enum.with_index() |> Enum.find(fn {{a, b}, _i} -> a != b end) do
      nil ->
        " One is a prefix of the other (#{length(old)} against #{length(new)})."

      {{a, b}, i} ->
        " First difference at item #{i}:\n  recorded: #{inspect(a, limit: 30)}\n  now:      #{inspect(b, limit: 30)}"
    end
  end

  defp pick(streams, {:percepts, body}), do: Map.fetch!(streams.percepts, body)
  defp pick(streams, what), do: Map.fetch!(streams, what)
end
