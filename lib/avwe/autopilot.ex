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
     An entry has a **window**: it is due from its occurrence for the day
     (its time plus the body's jitter for that day) up to the next entry's
     occurrence, the last entry up to and including midnight (so a history
     step ending on the stroke of midnight still finds it), unless it has
     been done that day. `autopilot.done` maps entry index to the day
     number, of the entry's own time, up to which it is done (or missed):
     an entry jittered past midnight is still that day's, and the day
     before is looked at as well as the day the step ends in. An entry
     whose window has closed before it was done was **missed**: a decision
     point marks it done and says so (a `:decided` event with `why:
     :missed` and `reason: :window_closed`, no intent), so a body given
     back late in the day runs only the latest entry still in its window,
     never the stale ones back to back. An entry starts its plan only with
     a **start margin**: at least #{60} minutes left in its window, unless
     the entry has only just come due (its occurrence falls within this
     step, so the body was not late for it, the window is simply short);
     one found with less is marked done as missed too, with `reason:
     :too_late`, so a body given back at 07:30 does not set out on a walk
     the survey will cut short at 08:00. When several are due, the last is
     taken and all of them are marked done. Taking an entry starts its
     **plan** (below).
  2. **Kindle at home** (0.8, urgent). When the air is cold, below
     `#{15.0} °C` (the air `Avwe.Prose` calls cool), no burning source is
     felt at the body's cell (`Avwe.Systems.Fire.felt/2`), and the body is
     at home with a cold hearth there that has fuel and is invited: kindle
     it. This is the one candidate that interrupts anything.
  3. **Stay by the fire** (0.6). Dark and cold, with a burning source felt
     where the body stands: wait thirty minutes. The body keeps its place by
     the fire instead of setting off home and turning back for the warmth.
  4. **Go to a fire** (0.7). Dark and cold, nothing felt, and a burning
     hearth the body can see (as fires are seen: within sight, or 200 m at
     night) stands at a known place: go there.
  5. **Rest** (0.5). Dark (from sunset up to sunrise, when `env.light` is
     0.0) and at home: wait until dawn. Dark, away from home and no fire
     felt: go home (0.55).
  6. **Idle**. By day, away from home: go home (0.3), so a body given back
     wherever it was does not stand there all day. Otherwise wait (0.1)
     until the next of the day's routine occurrences, or #{60} minutes,
     whichever comes sooner: quiet and cheap, a decision an hour at most,
     and a routine entry that comes due still cuts the wait short.

  ## Plans

  A routine entry's steps run in sequence. The body's `:autopilot` record
  keeps `plan: %{entry: index, day: day, step: n, steps: [remaining], ref:
  pending_ref, until: time | nil}` while one runs: `step` is the index of
  the step under way in the entry's `do`, `ref` its intent's ref, `day`
  the day the entry is done for, and `until`, for a wait step, the time
  the wait ends. The step's `:action_result`, read from the region's
  outbox in the step it is emitted, ends it: `:success` submits the next
  step, or ends the plan after the last; anything else (`:blocked`,
  `:failure`, `:interrupted`) abandons the plan, announced with a
  `:decided` event whose `why` is `:plan_abandoned`. A step refused
  outright never replaced what the body was doing, so its result is read
  whatever the body is doing, not only when it stands idle. An entry is
  marked done when its plan starts, so a plan that fails is not retried
  that day.

  A plan is routine work: it resists needs, not the next entry. While one
  runs, the urgent kindle may cut in (it is instant, and leaves the plan
  under way), and a routine entry that comes due may replace a step that is
  a wait, which abandons the plan with reason `:superseded`; rest, the
  fires and idling never do, so the morning walk is not cut short by a
  cold hour, and the night's rest does not lock out the walk at dawn. An
  entry whose first step is the very intent the body is already on (same
  verb, target and params) does not interrupt it: the entry is marked
  done, the running action is adopted as that step, and the plan goes on
  from the next (announced with `adopted: ref` in place of `intent_ref`).
  The rest entry's plan begins with `go` home, so a body given back away
  from home at night still ends it at home: a `go` to a place the body is
  already at succeeds as `:already_there`, and the rest follows.

  When a controller takes the body the plan is kept. On release, if the
  entry's window is still open, the plan **resumes** at the pending step,
  serving only what is left of it: a `go` is issued again (to a place the
  body is already at it succeeds as `:already_there`); a wait is issued
  again for the seconds that remain until the time recorded in `until`
  (`until: :dawn` keeps its moment), and is skipped altogether when none
  remain or when the controller moved the body more than #{2} cells from
  the target of the `go` step before it, so the next step brings it back
  on course (a plan whose last step is skipped is done). If the window has
  closed the plan is dropped, announced as abandoned with reason
  `:window_closed`, the entry is done for the day, and what the body does
  next follows the interrupt rules below, so a journey the controller left
  it on is not cut by a candidate that is not urgent.

  ## Deciding

  A body decides when it has no action and no plan. When its action is a
  wait that is not a plan's (an idle, resting or fireside body, or one a
  controller left waiting), anything better interrupts it, and so does a
  routine entry that comes due. Any other action of its own, and a journey
  a controller left it on, goes on unless something urgent comes up.

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
  @idle_minutes 60
  @idle_s @idle_minutes * 60
  @stay_s 1_800
  @start_margin_minutes 60
  @start_margin @start_margin_minutes * 60
  @jitter_minutes 5
  @utilities %{
    routine: 0.6,
    kindle: @urgent,
    stay: 0.6,
    fire: 0.7,
    rest: 0.5,
    rest_away: 0.55,
    idle: 0.1,
    idle_away: 0.3
  }
  @order [:routine, :kindle, :stay, :fire, :rest, :idle]
  @fresh %{current: nil, why: nil, since: nil, done: %{}, plan: nil}

  @type step :: {atom()} | {atom(), keyword()}
  @type entry :: %{at: non_neg_integer(), do: [step()] | step(), note: String.t() | nil}
  @type done :: %{non_neg_integer() => integer()}
  @type plan :: %{
          entry: non_neg_integer(),
          day: integer(),
          step: non_neg_integer(),
          steps: [step()],
          ref: String.t() | nil,
          until: Calendar.time() | nil
        }

  @typedoc "Why a routine entry was missed."
  @type missed :: :window_closed | :too_late

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
  What a body does this step: act on a candidate, adopt its running action
  as a routine entry's first step, leave its action alone, or first end its
  plan (finished, or abandoned with the step's outcome and reason) and then
  one of those.
  """
  @type decision ::
          {:act, candidate()}
          | {:adopt, candidate()}
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

  @doc "What a body on its own does this step."
  @spec decide(Region.t(), Tick.t(), Region.entity_id()) :: decision()
  def decide(%Region{} = region, %Tick{} = tick, body) do
    action = Region.get(region, body, :action)
    record = Region.get(region, body, :autopilot) || @fresh
    plan = Map.get(record, :plan)
    result = plan && step_result(region, plan.ref)

    cond do
      result != nil -> step_ended(region, tick, body, record, plan, result, action)
      plan != nil and not under_way?(action, plan) -> resume(region, tick, body, record, action)
      action == nil -> {:act, best(region, tick, body, record)}
      true -> interrupt(region, tick, body, record, action, plan)
    end
  end

  @doc """
  Every candidate open to the body this step, in order of preference.
  """
  @spec candidates(Region.t(), Tick.t(), Region.entity_id(), map()) :: [candidate()]
  def candidates(%Region{} = region, %Tick{} = tick, body, record) do
    here = situation(region, tick, body)

    [
      routine(region, tick, body, record),
      kindle(region, body, here),
      stay(here),
      fire(region, body, here),
      rest(here),
      idle(region, tick, body, here)
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
  The body's routine entries due this step, as `{index, entry, day}`, the
  day before the step's end first and then that day, each day's earliest
  first: those whose window (see the module doc) holds the end of the step
  with the start margin to spare, and that `done` does not record as done
  up to `day`, the day of the entry's own time.
  """
  @spec due([entry()], Tick.t(), Region.entity_id(), done()) ::
          [{non_neg_integer(), entry(), integer()}]
  def due(entries, %Tick{} = tick, body, done) do
    for %{open?: true, late?: false} = window <- windows(entries, tick, body, done),
        do: {window.index, window.entry, window.day}
  end

  @doc """
  The body's routine entries missed, as `{index, entry, day, reason}`, in
  the order of `due/4`: their occurrence has passed, `done` does not record
  them for that day, and their window has closed (`:window_closed`) or has
  less than the start margin left (`:too_late`).
  """
  @spec missed([entry()], Tick.t(), Region.entity_id(), done()) ::
          [{non_neg_integer(), entry(), integer(), missed()}]
  def missed(entries, %Tick{} = tick, body, done) do
    for window <- windows(entries, tick, body, done),
        reason = missed_reason(window),
        reason != nil,
        do: {window.index, window.entry, window.day, reason}
  end

  defp missed_reason(%{open?: false}), do: :window_closed
  defp missed_reason(%{late?: true}), do: :too_late
  defp missed_reason(_window), do: nil

  # Each entry's occurrence that has come, for the day before the step's
  # end and for that day (a window never reaches further back), when `done`
  # does not record the entry for that day, with whether its window still
  # holds the end of the step and, if so, whether the body is too late to
  # start it (the occurrence fell in an earlier step and less than the
  # start margin is left). The window runs from the occurrence up to the
  # next entry's, in the body's jittered frame for the day; the last
  # entry's up to and including the day's midnight (or the occurrence
  # itself, when the jitter put it past midnight).
  defp windows(entries, tick, body, done) do
    day = Calendar.day()
    now = Tick.end_time(tick)
    today = Integer.floor_div(now, day)

    for key <- [today - 1, today],
        offset = offset(tick, body, key),
        day_start = key * day,
        {entry, index} <- Enum.with_index(entries),
        occurrence = day_start + entry.at + offset,
        occurrence <= now,
        not done?(done, index, key) do
      until =
        case Enum.at(entries, index + 1) do
          nil -> max(day_start + day, occurrence)
          next -> day_start + next.at + offset - 1
        end

      open? = now <= until
      late? = open? and occurrence <= tick.time and until - now < @start_margin
      %{index: index, entry: entry, day: key, open?: open?, late?: late?}
    end
  end

  # The next of the body's routine occurrences today after the end of the
  # step, or `nil`.
  defp next_occurrence(entries, tick, body) do
    day = Calendar.day()
    now = Tick.end_time(tick)
    today = Integer.floor_div(now, day)
    offset = offset(tick, body, today)

    entries
    |> Enum.map(&(today * day + &1.at + offset))
    |> Enum.filter(&(&1 > now))
    |> Enum.min(fn -> nil end)
  end

  defp done?(done, index, key) do
    case done do
      %{^index => day} -> day >= key
      _not_yet -> false
    end
  end

  @doc """
  Each body's routine offset for the day the step starts in, in seconds,
  from `Avwe.Tick.rng/2` seeded at the day's start with the body's id: the
  same at every step of the day, whatever the step length, and the same
  whoever else is in the region.
  """
  @spec jitter(Tick.t(), [Region.entity_id()]) :: %{Region.entity_id() => integer()}
  def jitter(%Tick{} = tick, bodies) do
    today = Integer.floor_div(tick.time, Calendar.day())
    Map.new(bodies, &{&1, offset(tick, &1, today)})
  end

  # The body's routine offset for day number `day`, in seconds.
  defp offset(tick, body, day) do
    rng = Tick.rng(%{tick | time: day * Calendar.day()}, {__MODULE__, body})
    {minutes, _rng} = :rand.uniform_s(2 * @jitter_minutes + 1, rng)
    (minutes - @jitter_minutes - 1) * Calendar.minute()
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

  defp best(region, tick, body, record), do: region |> candidates(tick, body, record) |> choose()

  # The body has an action. An entry whose first step is that very action
  # adopts it. Otherwise a plan's step yields to something urgent, and a
  # plan's wait to a routine entry come due; a wait that is not a plan's
  # (the body's own, or one a controller left it on) to anything better and
  # to a routine entry; anything else only to something urgent.
  defp interrupt(region, tick, body, record, action, plan) do
    best = best(region, tick, body, record)

    cond do
      best.why == :routine and same_intent?(best.intent, action) ->
        {:adopt, best}

      plan != nil ->
        on_plan(best, record, action)

      wait?(action) and (best.why == :routine or better?(best, record)) ->
        {:act, best}

      urgent?(best, record) ->
        {:act, best}

      true ->
        :stay
    end
  end

  # A plan's step yields to something urgent, which leaves the plan under
  # way, and a plan's wait to a routine entry come due, which supersedes it.
  defp on_plan(best, record, action) do
    cond do
      urgent?(best, record) ->
        {:act, best}

      best.why == :routine and wait?(action) ->
        {:plan_abandoned, {nil, :superseded}, {:act, best}}

      true ->
        :stay
    end
  end

  # The plan's pending step has ended this step. On success the next step
  # follows, or the plan is done; anything else abandons it. A step that was
  # refused outright, or an instant one, ends without having replaced the
  # body's action, so what comes after the plan is decided as for a body
  # with no plan: freely when idle, under the interrupt rules otherwise.
  defp step_ended(region, tick, body, record, plan, result, action) do
    case {result, plan.steps} do
      {%{outcome: :success}, [_step | _rest]} ->
        {:act,
         plan_candidate(Region.get(region, body, :routine), plan.entry, plan.day, plan.step + 1)}

      {%{outcome: :success}, []} ->
        {:plan_done, after_plan(region, tick, body, record, action)}

      {%{outcome: outcome, reason: reason}, _steps} ->
        {:plan_abandoned, {outcome, reason}, after_plan(region, tick, body, record, action)}
    end
  end

  # A plan whose pending step is neither under way nor ending this step: its
  # result went by while a controller had the body. If the entry's window is
  # still open what is left of the step is issued again; if not, the plan is
  # dropped and the body goes on under the interrupt rules.
  defp resume(region, tick, body, %{plan: plan} = record, action) do
    entries = Region.get(region, body, :routine) || []

    if open?(entries, plan, tick, body),
      do: remainder(region, tick, body, record, entries, action),
      else:
        {:plan_abandoned, {nil, :window_closed}, after_plan(region, tick, body, record, action)}
  end

  defp open?(entries, plan, tick, body) do
    Enum.any?(windows(entries, tick, body, %{}), fn window ->
      window.open? and window.index == plan.entry and window.day == plan.day
    end)
  end

  # The pending step, or what is left of it. A wait is served for the
  # seconds that remain until the end recorded when it started, and skipped
  # when none remain or the controller moved the body off the place the
  # `go` step before it reached: the next step brings it back on course.
  defp remainder(region, tick, body, %{plan: plan} = record, entries, action) do
    steps = entries |> Enum.at(plan.entry) |> steps()
    before = if plan.step > 0, do: Enum.at(steps, plan.step - 1)

    case Enum.at(steps, plan.step) do
      {:wait, opts} ->
        left = time_left(plan, tick)

        if off_course?(region, body, before) or left == :none,
          do: skip(region, tick, body, record, entries, action),
          else: {:act, wait_left(entries, plan, opts, left)}

      _step ->
        {:act, plan_candidate(entries, plan.entry, plan.day, plan.step)}
    end
  end

  # The seconds left of the plan's wait at the end of the step: `:all` when
  # no end was recorded, `:none` when it has passed.
  defp time_left(plan, tick) do
    now = Tick.end_time(tick)

    case Map.get(plan, :until) do
      nil -> :all
      until when until <= now -> :none
      until -> until - now
    end
  end

  # The wait step again, for what is left of it: a `for:` wait for the
  # seconds left, an `until:` wait for its moment, still to come.
  defp wait_left(entries, plan, opts, left) do
    candidate = plan_candidate(entries, plan.entry, plan.day, plan.step)

    if is_integer(left) and Keyword.get(opts, :params, %{})[:for] != nil,
      do: %{candidate | intent: {:wait, params: %{for: left}}},
      else: candidate
  end

  # The pending step is passed over: the next follows, or the plan is done.
  defp skip(region, tick, body, %{plan: plan} = record, entries, action) do
    case plan.steps do
      [_next | _rest] -> {:act, plan_candidate(entries, plan.entry, plan.day, plan.step + 1)}
      [] -> {:plan_done, after_plan(region, tick, body, record, action)}
    end
  end

  # The body is more than two cells from the target of a `go` step.
  defp off_course?(region, body, {:go, opts}) do
    case Region.get(region, opts[:target], :position) do
      nil -> false
      there -> Space.distance(Region.get(region, body, :position), there) > @at_place_cells
    end
  end

  defp off_course?(_region, _body, _step), do: false

  defp after_plan(region, tick, body, record, nil), do: {:act, best(region, tick, body, record)}

  defp after_plan(region, tick, body, record, action),
    do: interrupt(region, tick, body, record, action, nil)

  # The pending step's result among the events emitted so far. Refs are
  # unique, and this step's events are at the head of the outbox.
  defp step_result(%Region{outbox: outbox}, ref) do
    Enum.find_value(outbox, fn
      %Event{type: :action_result, data: %{ref: ^ref} = data} -> data
      _other -> nil
    end)
  end

  defp under_way?(%{ref: ref}, %{ref: ref}), do: true
  defp under_way?(_action, _plan), do: false

  defp urgent?(candidate, record), do: candidate.utility >= @urgent and better?(candidate, record)

  defp wait?(%{verb: :wait}), do: true
  defp wait?(_action), do: false

  defp better?(candidate, %{current: nil}), do: candidate.utility > 0.0
  defp better?(candidate, %{current: current}), do: candidate.utility > current

  # The same verb, target and params as the running action.
  defp same_intent?({verb, opts}, %{verb: verb} = action) do
    opts[:target] == action.target and Keyword.get(opts, :params, %{}) == action.params
  end

  defp same_intent?(_intent, _action), do: false

  # Candidates

  defp routine(region, tick, body, record) do
    with entries when entries != nil <- Region.get(region, body, :routine),
         [_due | _rest] = due <- due(entries, tick, body, record.done) do
      {index, _entry, day} = List.last(due)

      entries
      |> plan_candidate(index, day, 0)
      |> Map.put(:done, Map.new(due, fn {index, _entry, day} -> {index, day} end))
    else
      _nothing_due -> nil
    end
  end

  # The candidate for step `n` of an entry's plan.
  defp plan_candidate(entries, index, day, n) do
    entry = Enum.at(entries, index)
    [step | rest] = entry |> steps() |> Enum.drop(n)

    %{
      utility: @utilities.routine,
      intent: step_intent(step),
      why: :routine,
      entry: index,
      note: entry.note,
      step: n,
      plan: %{entry: index, day: day, step: n, steps: rest, ref: nil, until: nil}
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

  # The known place at the nearest burning hearth the body can see: within
  # sight, or 200 m, as a fire is seen at night.
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
    |> Enum.filter(fn {distance, _source} -> distance > 0 and distance <= sight end)
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

  defp idle(_region, _tick, _body, %{dark?: false, away?: true, home: home}),
    do: %{candidate(:idle, {:go, target: home}) | utility: @utilities.idle_away}

  defp idle(region, tick, body, _here),
    do: candidate(:idle, {:wait, params: %{for: idle_s(region, tick, body)}})

  # Up to an hour, or less when a routine occurrence comes sooner today.
  defp idle_s(region, tick, body) do
    case next_occurrence(Region.get(region, body, :routine) || [], tick, body) do
      nil -> @idle_s
      next -> min(@idle_s, next - Tick.end_time(tick))
    end
  end

  defp candidate(why, intent) when why in @order,
    do: %{utility: @utilities[why], intent: intent, why: why}
end
