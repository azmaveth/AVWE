defmodule Avwe.Autopilot do
  @moduledoc """
  What a body does when nobody is driving it. Pure.

  `Avwe.Systems.Autopilot` asks this module, once per step for every body on
  its own, what the body does next (`decide/4`). A body with nothing under
  way picks the best of a few candidates, each `%{utility: float, intent:
  {verb, opts}, why: atom}`. The best wins; ties go to the earlier candidate
  in the order below.

  1. **Routine entry due** (0.6). A body's `:routine` component is a list of
     entries `%{at: seconds_of_day, do: [step], note: string | nil}`, sorted
     by time. Each step is an intent, `{verb, opts}` or `{verb}`, and
     `{:rest}` means wait until dawn; a single step stands for a plan of one.
     An entry is due when its occurrence for the day (its time plus the
     body's jitter) is at or before the end of the step and it has not been
     done today (`autopilot.done`, entry index to day number), so an entry
     whose moment passed while a controller had the body fires at the next
     decision point. When several are due, the last is taken and all of
     them are marked done. Taking an entry starts its **plan** (below).
  2. **Kindle at home** (0.8, urgent). When the air is cold, below
     `#{15.0} °C` (the air `Avwe.Prose` calls cool), no burning source is
     felt at the body's cell (`Avwe.Systems.Fire.felt/2`), and the body is
     at home with a cold hearth there that has fuel and is invited: kindle
     it. This is the one candidate that interrupts anything.
  3. **Stay by the fire** (0.6). Dark and cold, with a burning source felt
     where the body stands: wait thirty minutes. The body keeps its place by
     the fire instead of setting off home and turning back for the warmth.
  4. **Go to a fire** (0.7). Dark and cold, nothing felt, and a burning
     hearth the body can see (as fires are seen: within sight or 200 m)
     stands at a known place nearer than 500 m: go there.
  5. **Rest** (0.5). Dark (from sunset up to sunrise, when `env.light` is
     0.0) and at home: wait until dawn. Dark, away from home and no fire
     felt: go home (0.55).
  6. **Idle** (0.1): wait ten minutes.

  ## Plans

  A routine entry's steps run in sequence. The body's `:autopilot` record
  keeps `plan: %{entry: index, steps: [remaining], ref: pending_ref}` while
  one runs: `ref` is the step under way. The step's `:action_result`, read
  from the region's outbox in the step it is emitted, ends it: `:success`
  submits the next step, or ends the plan after the last; anything else
  (`:blocked`, `:failure`, `:interrupted`) abandons the plan, announced
  with a `:decided` event whose `why` is `:plan_abandoned`. A step refused
  outright never replaced what the body was doing, so its result is read
  whatever the body is doing, not only when it stands idle.
  An entry is marked done when its plan starts, so a plan that fails is not
  retried that day. A plan is routine work: while one runs, only the urgent
  kindle may cut in; rest, the fires and idling never do, so the morning
  walk is not cut short by a cold hour. When a controller takes the body
  the plan is dropped and does not resume on release; the entry runs again
  the next day.

  ## Deciding

  A body decides when it has no action and no plan. When its action is a
  wait of its own that is not a plan's (an idle, resting or fireside body),
  anything better interrupts it, and so does a routine entry that comes due.
  Any other action of its own, and a journey a controller left it on, goes
  on unless something urgent comes up.

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
  `[-#{5}, +#{5}]` minutes, drawn from `Avwe.Tick.rng/2` seeded at the day's
  start with the body's id (`{Avwe.Autopilot, body}`), so bodies with the
  same routine do not move in lockstep, and adding a body never shifts
  another's offsets. Nothing else is random.
  """

  alias Avwe.{Calendar, Event, Perception, Region, Space, Terrain, Tick}
  alias Avwe.Systems.{Daylight, Fire, Heat}

  @urgent 0.8
  @cold_c 15.0
  @invited_c 25.0
  @at_place_cells 2
  @fire_sight_cells 20
  @fire_reach_cells 50
  @idle_s 600
  @stay_s 1_800
  @jitter_minutes 5
  @utilities %{
    routine: 0.6,
    kindle: @urgent,
    stay: 0.6,
    fire: 0.7,
    rest: 0.5,
    rest_away: 0.55,
    idle: 0.1
  }
  @order [:routine, :kindle, :stay, :fire, :rest, :idle]
  @fresh %{current: nil, why: nil, since: nil, done: %{}, plan: nil}

  @type step :: {atom()} | {atom(), keyword()}
  @type entry :: %{at: non_neg_integer(), do: [step()] | step(), note: String.t() | nil}
  @type done :: %{non_neg_integer() => integer()}
  @type plan :: %{entry: non_neg_integer(), steps: [step()], ref: String.t() | nil}

  @type candidate :: %{
          required(:utility) => float(),
          required(:intent) => {atom(), keyword()},
          required(:why) => atom(),
          optional(:done) => done(),
          optional(:entry) => non_neg_integer(),
          optional(:note) => String.t() | nil,
          optional(:step) => non_neg_integer(),
          optional(:plan) => plan()
        }

  @typedoc """
  What a body does this step: act on a candidate, leave its action alone, or
  first end its plan (finished, or abandoned with the step's outcome and
  reason) and then one of those two.
  """
  @type decision ::
          {:act, candidate()}
          | :stay
          | {:plan_done, {:act, candidate()} | :stay}
          | {:plan_abandoned, {atom() | nil, atom()}, {:act, candidate()} | :stay}

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
  What a body on its own does this step. `jitter_s` is the body's routine
  offset for the day (`jitter/2`).
  """
  @spec decide(Region.t(), Tick.t(), Region.entity_id(), integer()) :: decision()
  def decide(%Region{} = region, %Tick{} = tick, body, jitter_s) do
    action = Region.get(region, body, :action)
    record = Region.get(region, body, :autopilot) || @fresh
    plan = Map.get(record, :plan)
    result = plan && step_result(region, plan.ref)

    cond do
      result != nil -> step_ended(region, tick, body, jitter_s, record, plan, result, action)
      plan != nil and action == nil -> plan_lost(region, tick, body, jitter_s, record)
      action == nil -> {:act, best(region, tick, body, jitter_s, record)}
      true -> interrupt(region, tick, body, jitter_s, record, action, plan)
    end
  end

  @doc """
  Every candidate open to the body this step, in order of preference.
  """
  @spec candidates(Region.t(), Tick.t(), Region.entity_id(), integer(), map()) :: [candidate()]
  def candidates(%Region{} = region, %Tick{} = tick, body, jitter_s, record) do
    here = situation(region, tick, body)

    [
      routine(region, tick, body, jitter_s, record),
      kindle(region, body, here),
      stay(here),
      fire(region, body, here),
      rest(here),
      idle()
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Where the body stands and how the night finds it: at home or away, in
  # cold air (below `@cold_c`), warmed by a fire felt at its cell, in the
  # dark.
  defp situation(region, tick, body) do
    position = Region.get(region, body, :position)
    home = Region.get(region, body, :home)
    home_position = home && Region.get(region, home, :position)
    at_home? = home_position != nil and Space.distance(position, home_position) <= @at_place_cells

    %{
      position: position,
      home: home,
      at_home?: at_home?,
      away?: home_position != nil and not at_home?,
      cold?: Map.get(region.env, :air_c, @cold_c) < @cold_c,
      warmed?: Fire.felt(region, position) != nil,
      dark?: dark?(tick)
    }
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
  The routine entries due this step, as `{index, entry, day}`, earliest
  first: those whose occurrence for the day the step ends in is at or
  before the step's end and that `done` does not record for that day.
  """
  @spec due([entry()], Tick.t(), integer(), done()) ::
          [{non_neg_integer(), entry(), integer()}]
  def due(entries, %Tick{} = tick, jitter_s, done) do
    day = Calendar.day()
    today = Integer.floor_div(Tick.end_time(tick), day)

    for {entry, index} <- Enum.with_index(entries),
        occurrence = Tick.last_occurrence(tick, day, entry.at + jitter_s),
        Integer.floor_div(occurrence, day) == today,
        Map.get(done, index) != today,
        do: {index, entry, today}
  end

  @doc """
  Each body's routine offset for the day the step starts in, in seconds,
  from `Avwe.Tick.rng/2` seeded at the day's start with the body's id: the
  same at every step of the day, whatever the step length, and the same
  whoever else is in the region.
  """
  @spec jitter(Tick.t(), [Region.entity_id()]) :: %{Region.entity_id() => integer()}
  def jitter(%Tick{} = tick, bodies) do
    day_start = Integer.floor_div(tick.time, Calendar.day()) * Calendar.day()

    Map.new(bodies, fn body ->
      rng = Tick.rng(%{tick | time: day_start}, {__MODULE__, body})
      {minutes, _rng} = :rand.uniform_s(2 * @jitter_minutes + 1, rng)
      {body, (minutes - @jitter_minutes - 1) * Calendar.minute()}
    end)
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

  # Deciding

  defp best(region, tick, body, jitter_s, record),
    do: region |> candidates(tick, body, jitter_s, record) |> choose()

  # The body has an action. A plan's step yields only to something urgent; a
  # wait of the body's own (not a plan's) to anything better and to a routine
  # entry come due; anything else only to something urgent.
  defp interrupt(region, tick, body, jitter_s, record, action, plan) do
    best = best(region, tick, body, jitter_s, record)

    cond do
      plan != nil -> if urgent?(best, record), do: {:act, best}, else: :stay
      own_wait?(action, body) and (best.why == :routine or better?(best, record)) -> {:act, best}
      urgent?(best, record) -> {:act, best}
      true -> :stay
    end
  end

  # The plan's pending step has ended this step. On success the next step
  # follows, or the plan is done; anything else abandons it. A step that was
  # refused outright, or an instant one, ends without having replaced the
  # body's action, so what comes after the plan is decided as for a body
  # with no plan: freely when idle, under the interrupt rules otherwise.
  defp step_ended(region, tick, body, jitter_s, record, plan, result, action) do
    case {result, plan.steps} do
      {%{outcome: :success}, [step | rest]} ->
        {:act, plan_candidate(Region.get(region, body, :routine), plan.entry, step, rest)}

      {%{outcome: :success}, []} ->
        {:plan_done, after_plan(region, tick, body, jitter_s, record, action)}

      {%{outcome: outcome, reason: reason}, _steps} ->
        {:plan_abandoned, {outcome, reason},
         after_plan(region, tick, body, jitter_s, record, action)}
    end
  end

  # No action, a plan, and no result for its step this step: the result
  # went by unseen (it never should), so the plan is given up rather than
  # waited on for ever.
  defp plan_lost(region, tick, body, jitter_s, record),
    do: {:plan_abandoned, {nil, :lost}, {:act, best(region, tick, body, jitter_s, record)}}

  defp after_plan(region, tick, body, jitter_s, record, nil),
    do: {:act, best(region, tick, body, jitter_s, record)}

  defp after_plan(region, tick, body, jitter_s, record, action),
    do: interrupt(region, tick, body, jitter_s, record, action, nil)

  # The pending step's result among the events emitted so far. Refs are
  # unique, and this step's events are at the head of the outbox.
  defp step_result(%Region{outbox: outbox}, ref) do
    Enum.find_value(outbox, fn
      %Event{type: :action_result, data: %{ref: ^ref} = data} -> data
      _other -> nil
    end)
  end

  defp urgent?(candidate, record), do: candidate.utility >= @urgent and better?(candidate, record)

  defp own_wait?(%{verb: :wait, ref: ref}, body), do: String.starts_with?(ref, "auto-#{body}-")
  defp own_wait?(_action, _body), do: false

  defp better?(candidate, %{current: nil}), do: candidate.utility > 0.0
  defp better?(candidate, %{current: current}), do: candidate.utility > current

  # Candidates

  defp routine(region, tick, body, jitter_s, record) do
    with entries when entries != nil <- Region.get(region, body, :routine),
         [_due | _rest] = due <- due(entries, tick, jitter_s, record.done) do
      {index, entry, _today} = List.last(due)
      [step | rest] = steps(entry)

      entries
      |> plan_candidate(index, step, rest)
      |> Map.put(:done, Map.new(due, fn {index, _entry, today} -> {index, today} end))
    else
      _nothing_due -> nil
    end
  end

  defp plan_candidate(entries, index, step, rest) do
    entry = Enum.at(entries || [], index)

    %{
      utility: @utilities.routine,
      intent: step_intent(step),
      why: :routine,
      entry: index,
      note: entry && entry.note,
      step: if(entry, do: length(steps(entry)) - length(rest) - 1, else: 0),
      plan: %{entry: index, steps: rest, ref: nil}
    }
  end

  defp steps(%{do: steps}), do: List.wrap(steps)

  defp step_intent({:rest}), do: {:wait, params: %{until: :dawn}}
  defp step_intent({verb}), do: {verb, []}
  defp step_intent({verb, opts}), do: {verb, opts}

  defp kindle(region, body, %{at_home?: true, cold?: true, warmed?: false, position: position}) do
    case cold_hearth(region, body, position) do
      nil -> nil
      hearth -> candidate(:kindle, {:kindle, target: hearth})
    end
  end

  defp kindle(_region, _body, _here), do: nil

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

  defp stay(%{dark?: true, cold?: true, warmed?: true}),
    do: candidate(:stay, {:wait, params: %{for: @stay_s}})

  defp stay(_here), do: nil

  defp fire(region, body, %{dark?: true, cold?: true, warmed?: false, position: position}) do
    case fire_in_sight(region, body, position) do
      nil -> nil
      place -> candidate(:fire, {:go, target: place})
    end
  end

  defp fire(_region, _body, _here), do: nil

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

  defp rest(%{dark?: false}), do: nil
  defp rest(%{at_home?: true}), do: candidate(:rest, {:wait, params: %{until: :dawn}})

  defp rest(%{away?: true, warmed?: false, home: home}),
    do: %{candidate(:rest, {:go, target: home}) | utility: @utilities.rest_away}

  defp rest(_here), do: nil

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
end
