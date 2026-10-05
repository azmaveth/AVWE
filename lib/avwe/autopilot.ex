defmodule Avwe.Autopilot do
  @moduledoc """
  What a body does when nobody is driving it. Pure.

  `Avwe.Systems.Autopilot` asks this module, once per step for every body on
  its own, what the body does next. The answer is a utility pick over a few
  candidates, each `%{utility: float, intent: {verb, opts}, why: atom}`. The
  best wins; ties go to the earlier candidate in the order below.

  1. **Routine entry due** (0.6). A body's `:routine` component is a list of
     entries `%{at: seconds_of_day, do: {verb, opts}, note: string | nil}`,
     sorted by time. An entry is due when the step crosses its time
     (`Avwe.Tick.crossed?/3`, shifted by the body's jitter for the day) and
     it has not been done today (`autopilot.done`, entry index to day
     number). When several are due in one long step, the last one is taken
     and all of them are marked done. `{:rest}` means wait until dawn.
  2. **Warmth** (0.8 when cold, else absent). Cold means the air is below
     `#{15.0} °C`, the air `Avwe.Prose` calls cool, and no burning source is
     felt at the body's cell (`Avwe.Systems.Fire.felt/2`). At home with a
     cold hearth there that has fuel and is invited: kindle it. Otherwise,
     when a burning hearth the body can see (as fires are seen: within
     sight or 200 m) stands at a known place nearer than 500 m: go there.
     Otherwise, away from home: go home, at 0.55, so that being cold on an
     errand does not cut the errand short the way a fire to be lit does.
  3. **Rest** (0.5). When it is dark (from sunset up to sunrise, when
     `env.light` is 0.0) and the body is at home: wait until dawn. Dark and
     away from home: go home (0.55).
  4. **Idle** (0.1): wait ten minutes.

  A body decides when it has no action, when its action is a wait of its
  own (an idle or resting body is interrupted by anything better, and by a
  routine entry that comes due), or when a candidate is urgent (at least
  0.8) and better than what it recorded for the running action. A body
  whose controller left it mid-journey carries the journey on, unless
  something urgent comes up.

  ## Invited hearths

  The Hearth Compact (`docs/DESIGN.md`, 6.6 and 7.2) made physical: a hearth
  is *invited* when the river bed beside it, the nearest channel cell within
  `Avwe.Terrain.near_channel_cells/0`, still holds the river's warmth, at
  least `@invited_c` (#{25.0} °C, a summer afternoon's air) by
  `Avwe.Systems.Heat.ground_c/3`. The town stands on clay, which the heat
  model does not warm from the river, so the warmth a kiln-house holds is
  read from the bank the town sits on. In 812 the bed beside Ember Reach is
  33 °C all night; in 813 it is 17 to 23 °C, so the same Mira, with the same
  wood on the same cold night, lights her hearth in 812 and does not in
  813: "many chimneys went cold". Bodies whose `:norms` include
  `:invited_fire` only kindle invited hearths; bodies without that norm
  kindle any hearth with fuel. A hearth with no channel within 80 m is
  never invited.

  ## Jitter

  Routine times get a deterministic offset per body per day in
  `[-#{5}, +#{5}]` minutes, drawn from `Avwe.Tick.rng/2` at the day's
  start, so bodies with the same routine do not move in lockstep. Nothing
  else is random.
  """

  alias Avwe.{Calendar, Perception, Region, Space, Terrain, Tick}
  alias Avwe.Systems.{Daylight, Fire, Heat}

  @urgent 0.8
  @cold_c 15.0
  @invited_c 25.0
  @at_place_cells 2
  @fire_sight_cells 20
  @fire_reach_cells 50
  @idle_s 600
  @jitter_minutes 5
  @utilities %{
    routine: 0.6,
    warmth: @urgent,
    cold_away: 0.55,
    rest: 0.5,
    rest_away: 0.55,
    idle: 0.1
  }
  @order [:routine, :warmth, :rest, :idle]
  @fresh %{current: nil, why: nil, since: nil, done: %{}}

  @type candidate :: %{
          required(:utility) => float(),
          required(:intent) => {atom(), keyword()},
          required(:why) => atom(),
          optional(:done) => %{non_neg_integer() => integer()},
          optional(:entry) => non_neg_integer(),
          optional(:note) => String.t() | nil
        }

  @doc "The `:autopilot` component of a body that has decided nothing yet."
  @spec fresh() :: map()
  def fresh, do: @fresh

  @doc "The ground temperature, in °C, from which a hearth is invited."
  @spec invited_c() :: float()
  def invited_c, do: @invited_c

  @doc "The air temperature, in °C, below which a body wants warmth."
  @spec cold_c() :: float()
  def cold_c, do: @cold_c

  @doc """
  What a body on its own does this step: `{:act, candidate}` with the
  candidate to submit, or `:stay` to leave its current action alone.
  `jitter_s` is the body's routine offset for the day (`jitter/2`).
  """
  @spec decide(Region.t(), Tick.t(), Region.entity_id(), integer()) :: {:act, candidate()} | :stay
  def decide(%Region{} = region, %Tick{} = tick, body, jitter_s) do
    action = Region.get(region, body, :action)
    record = Region.get(region, body, :autopilot) || @fresh
    best = region |> candidates(tick, body, jitter_s, record) |> choose()

    cond do
      action == nil -> {:act, best}
      own_wait?(action, body) and (best.why == :routine or better?(best, record)) -> {:act, best}
      best.utility >= @urgent and better?(best, record) -> {:act, best}
      true -> :stay
    end
  end

  @doc """
  Every candidate open to the body this step, in order of preference.
  """
  @spec candidates(Region.t(), Tick.t(), Region.entity_id(), integer(), map()) :: [candidate()]
  def candidates(%Region{} = region, %Tick{} = tick, body, jitter_s, record) do
    position = Region.get(region, body, :position)
    home = Region.get(region, body, :home)
    home_position = home && Region.get(region, home, :position)
    at_home? = home_position != nil and Space.distance(position, home_position) <= @at_place_cells
    away? = home_position != nil and not at_home?

    [
      routine(region, tick, body, jitter_s, record),
      warmth(region, body, position, home, at_home?, away?),
      rest(tick, home, at_home?, away?),
      idle()
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "The best of `candidates`: the highest utility, ties to the earlier."
  @spec choose([candidate()]) :: candidate() | nil
  def choose(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.min_by(fn {candidate, index} -> {-candidate.utility, index} end, fn -> nil end)
    |> case do
      nil -> nil
      {candidate, _index} -> candidate
    end
  end

  @doc """
  Each body's routine offset for the day the step starts in, in seconds,
  from `Avwe.Tick.rng/2` seeded at the day's start: the same at every step
  of the day, whatever the step length. `bodies` must be sorted.
  """
  @spec jitter(Tick.t(), [Region.entity_id()]) :: %{Region.entity_id() => integer()}
  def jitter(%Tick{} = tick, bodies) do
    day_start = Integer.floor_div(tick.time, Calendar.day()) * Calendar.day()
    rng = Tick.rng(%{tick | time: day_start}, __MODULE__)

    {offsets, _rng} =
      Enum.map_reduce(bodies, rng, fn body, rng ->
        {minutes, rng} = :rand.uniform_s(2 * @jitter_minutes + 1, rng)
        {{body, (minutes - @jitter_minutes - 1) * Calendar.minute()}, rng}
      end)

    Map.new(offsets)
  end

  @doc """
  True when the hearth is invited: the river bed beside it still holds the
  river's warmth (see the module doc). Needs the region's terrain and heat
  field; without them nothing is invited.
  """
  @spec invited?(Region.t(), Region.entity_id()) :: boolean()
  def invited?(%Region{terrain: %Terrain{} = terrain, fields: %{heat: field}} = region, hearth) do
    near = Terrain.near_channel_cells()

    case Terrain.nearest_channel(terrain, Region.get(region, hearth, :position)) do
      {_index, bed, distance} when distance <= near ->
        Heat.ground_c(field, terrain, bed) >= @invited_c

      _no_channel ->
        false
    end
  end

  def invited?(_region, _hearth), do: false

  # Candidates

  defp routine(region, tick, body, jitter_s, record) do
    case Region.get(region, body, :routine) do
      nil ->
        nil

      entries ->
        day = Calendar.day()

        due =
          for {entry, index} <- Enum.with_index(entries),
              Tick.crossed?(tick, day, entry.at + jitter_s),
              on = Integer.floor_div(Tick.last_occurrence(tick, day, entry.at + jitter_s), day),
              Map.get(record.done, index) != on,
              do: {index, entry, on}

        case Enum.sort_by(due, fn {_index, entry, _on} -> entry.at end) do
          [] ->
            nil

          due ->
            {index, entry, _on} = List.last(due)

            %{
              utility: @utilities.routine,
              intent: routine_intent(entry.do),
              why: :routine,
              done: Map.new(due, fn {index, _entry, on} -> {index, on} end),
              entry: index,
              note: entry.note
            }
        end
    end
  end

  defp routine_intent({:rest}), do: {:wait, params: %{until: :dawn}}
  defp routine_intent({verb}), do: {verb, []}
  defp routine_intent({verb, opts}), do: {verb, opts}

  defp warmth(region, body, position, home, at_home?, away?) do
    if cold?(region, position) do
      hearth = at_home? && cold_hearth(region, body, position)
      fire = hearth || fire_in_sight(region, body, position)

      cond do
        hearth -> candidate(:warmth, {:kindle, target: hearth})
        fire -> candidate(:warmth, {:go, target: fire})
        away? -> %{candidate(:warmth, {:go, target: home}) | utility: @utilities.cold_away}
        true -> nil
      end
    end
  end

  defp cold?(region, position) do
    Map.get(region.env, :air_c, @cold_c) < @cold_c and Fire.felt(region, position) == nil
  end

  # The nearest hearth within reach that is cold, has wood, and may be lit:
  # any such hearth, or only an invited one for a body that keeps the Compact.
  defp cold_hearth(region, body, position) do
    compact? = :invited_fire in (Region.get(region, body, :norms) || [])

    region
    |> Fire.hearth_near(position)
    |> Enum.find_value(fn {id, hearth, _distance} ->
      if not hearth.burning and hearth.fuel_kg > 0 and (not compact? or invited?(region, id)),
        do: id
    end)
  end

  # The known place at the nearest burning hearth the body can see within 500 m.
  defp fire_in_sight(region, body, position) do
    knows = Region.get(region, body, :knows) || MapSet.new()
    sight = max(Perception.sight_cells(Map.get(region.env, :light, 0.0)), @fire_sight_cells)

    places =
      for id <- Region.with_components(region, [:place, :position]),
          MapSet.member?(knows, id),
          do: {id, Region.get(region, id, :position)}

    region
    |> Heat.sources()
    |> Enum.map(&{Space.distance(position, &1.position), &1})
    |> Enum.filter(fn {distance, _source} ->
      distance > 0 and distance <= sight and distance < @fire_reach_cells
    end)
    |> Enum.sort_by(fn {distance, source} -> {distance, source.id} end)
    |> Enum.find_value(fn {_distance, source} -> place_at(places, source.position) end)
  end

  defp place_at(places, position) do
    places
    |> Enum.map(fn {id, place_position} -> {Space.distance(position, place_position), id} end)
    |> Enum.filter(fn {distance, _id} -> distance <= @at_place_cells end)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      {_distance, id} -> id
    end
  end

  defp rest(tick, home, at_home?, away?) do
    cond do
      not dark?(tick) -> nil
      at_home? -> candidate(:rest, {:wait, params: %{until: :dawn}})
      away? -> %{candidate(:rest, {:go, target: home}) | utility: @utilities.rest_away}
      true -> nil
    end
  end

  # Night by the clock at the end of the step (as the light and the air are
  # read), from sunset up to sunrise: the light is 0.0 then, but it is still
  # 0.0 at sunrise itself, when a wait for dawn has just ended and the day,
  # not another night's rest, begins.
  defp dark?(%Tick{} = tick) do
    tod = tick |> Tick.end_time() |> Calendar.time_of_day()
    tod < Daylight.sunrise() or tod >= Daylight.sunset()
  end

  defp idle, do: candidate(:idle, {:wait, params: %{for: @idle_s}})

  defp candidate(why, intent) when why in @order,
    do: %{utility: @utilities[why], intent: intent, why: why}

  # Deciding

  defp own_wait?(%{verb: :wait, ref: ref}, body), do: String.starts_with?(ref, "auto-#{body}-")
  defp own_wait?(_action, _body), do: false

  defp better?(candidate, %{current: nil}), do: candidate.utility > 0.0
  defp better?(candidate, %{current: current}), do: candidate.utility > current
end
