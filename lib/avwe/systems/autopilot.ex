defmodule Avwe.Systems.Autopilot do
  @moduledoc """
  Drives the bodies nobody else is driving.

  For every body with an `:autopilot` component whose `control.holder` is
  `nil`, in sorted id order, asks `Avwe.Autopilot` what it does and, when it
  acts, queues the intent itself with `Avwe.Region.submit/2`, as controller
  `:autopilot` and ref `"auto-<body>-<step>"`. The intent is applied at the
  start of the next step like any other. Such intents are derived state:
  they are never journaled, and replay regenerates them identically because
  this is a pure function of the region and the tick, drawing randomness
  only from `Avwe.Tick.rng/2` (the routine jitter).

  A body with a controller is left entirely alone: no intents, and no
  cancelling of what it is doing. Its plan, if a routine entry's was under
  way, is kept: when control is released autopilot resumes at the next
  step, issuing what is left of the pending step if the entry's window is
  still open and dropping the plan if it has closed (`Avwe.Autopilot`,
  Plans). For that, a wait step's end is written into the plan as `until`
  when the step is issued, as `Avwe.Actions.wait_until/2` will set it.

  Each choice is recorded in the body's `:autopilot` component
  (`%{current: utility, why: atom, since: time, done: %{entry => day up to
  which it is done}, plan: plan | nil}`) and announced with a `:decided`
  event (`entity: body, data: %{why, intent_ref, utility}`, plus `entry`,
  `note` and `step` for a routine entry's step) that bodies never perceive:
  it is for the game master, like `:miracle`. A routine entry that adopts
  the body's running
  action as its first step submits nothing and names the action's ref as
  `adopted` instead of `intent_ref`. A plan that ends early is announced
  the same way with `why: :plan_abandoned`, the `entry`, the `step_ref`
  that ended it and its `outcome` and `reason` (`:superseded` when a
  routine entry replaced its wait, `:window_closed` when the body came
  back too late to go on with it). An entry whose window closed before it
  was done, or has too little of it left to start (`Avwe.Autopilot`, the
  start margin), is marked done and announced with `why: :missed`, the
  `entry` and the `reason` (`:window_closed` or `:too_late`), before the
  body decides.

  `prepare/1` marks the routine entries whose time is before the region's
  starting time as done for that day, and the rest for the day before: a
  world begun at noon did not miss the morning, nor the night before. The
  entries' own times count here, not the day's jitter, so an entry at the
  starting hour is still to come.
  """

  @behaviour Avwe.System

  alias Avwe.{Actions, Autopilot, Calendar, Event, Intent, Region, Tick}

  @impl Avwe.System
  def prepare(region) do
    tod = Calendar.time_of_day(region.time)
    today = Integer.floor_div(region.time, Calendar.day())

    region
    |> Region.with_components([:body, :autopilot, :routine])
    |> Enum.reduce(region, fn body, acc ->
      record = Region.get(acc, body, :autopilot)

      past =
        for {entry, index} <- Enum.with_index(Region.get(acc, body, :routine)),
            into: %{},
            do: {index, if(entry.at < tod, do: today, else: today - 1)}

      Region.put_component(acc, body, :autopilot, %{record | done: Map.merge(past, record.done)})
    end)
  end

  # A plan's step ends with the `:action_result` the brain reads from this
  # step's outbox, so this system must run after Movement and Waiting, which
  # emit those results, or a step's end would go by unseen.
  @impl Avwe.System
  def run(region, tick) do
    region
    |> Region.with_components([:body, :autopilot, :position])
    |> Enum.reduce({region, []}, fn body, {acc, events} ->
      if free?(acc, body),
        do: acc |> miss(tick, body, events) |> drive(tick, body),
        else: {acc, events}
    end)
  end

  defp free?(region, body) do
    case Region.get(region, body, :control) do
      %{holder: holder} -> holder == nil
      nil -> true
    end
  end

  # Marks the entries whose window closed before they were done.
  defp miss(region, tick, body, events) do
    record = Region.get(region, body, :autopilot)
    entries = Region.get(region, body, :routine) || []

    case Autopilot.missed(entries, tick, body, record.done) do
      [] ->
        {region, events}

      missed ->
        done = Map.new(missed, fn {index, _entry, day, _reason} -> {index, day} end)
        record = %{record | done: Map.merge(record.done, done)}

        announced =
          for {index, entry, _day, reason} <- missed,
              do:
                Event.new(:decided,
                  entity: body,
                  data: %{why: :missed, entry: index, note: entry.note, reason: reason}
                )

        {Region.put_component(region, body, :autopilot, record), events ++ announced}
    end
  end

  defp drive({region, events}, tick, body) do
    case Autopilot.decide(region, tick, body) do
      :stay ->
        {region, events}

      {:act, choice} ->
        act(region, tick, body, choice, events)

      {:adopt, choice} ->
        adopt(region, tick, body, choice, events)

      {:plan_done, then} ->
        region |> drop_plan(body) |> carry_on(tick, body, then, events)

      {:plan_abandoned, {outcome, reason}, then} ->
        {region, abandoned} = abandon(region, body, outcome, reason)
        carry_on(region, tick, body, then, events ++ [abandoned])
    end
  end

  defp carry_on(region, _tick, _body, :stay, events), do: {region, events}

  defp carry_on(region, tick, body, {:act, choice}, events),
    do: act(region, tick, body, choice, events)

  defp act(region, tick, body, choice, events) do
    ref = "auto-#{body}-#{tick.step}"
    {verb, opts} = choice.intent
    intent = Intent.new(body, verb, [ref: ref, controller: :autopilot] ++ opts)
    record = Region.get(region, body, :autopilot)

    # A routine step starts or carries on its plan; any other choice (the
    # kindle that cuts in) leaves the plan under way as it is.
    plan =
      case Map.get(choice, :plan) do
        nil -> Map.get(record, :plan)
        plan -> %{plan | ref: ref, until: wait_end(choice.intent, tick)}
      end

    data = Map.merge(announced(choice), %{intent_ref: ref})

    region =
      region
      |> Region.submit(intent)
      |> Region.put_component(body, :autopilot, decided(record, tick, choice, plan))

    {region, events ++ [Event.new(:decided, entity: body, data: data)]}
  end

  # The running action becomes the routine step: nothing is submitted.
  defp adopt(region, tick, body, choice, events) do
    record = Region.get(region, body, :autopilot)
    %{ref: ref} = Region.get(region, body, :action)
    plan = %{choice.plan | ref: ref}
    data = Map.merge(announced(choice), %{adopted: ref})
    region = Region.put_component(region, body, :autopilot, decided(record, tick, choice, plan))
    {region, events ++ [Event.new(:decided, entity: body, data: data)]}
  end

  # When a wait step will end: the intent is applied at the start of the
  # next step, which is the end of this one.
  defp wait_end({:wait, opts}, tick) do
    case Actions.wait_until(Keyword.get(opts, :params, %{}), Tick.end_time(tick)) do
      {:ok, until} -> until
      :error -> nil
    end
  end

  defp wait_end(_intent, _tick), do: nil

  defp decided(record, tick, choice, plan) do
    Map.merge(record, %{
      current: choice.utility,
      why: choice.why,
      since: Tick.end_time(tick),
      done: Map.merge(record.done, Map.get(choice, :done, %{})),
      plan: plan
    })
  end

  defp announced(choice) do
    choice
    |> Map.take([:entry, :note, :step])
    |> Map.merge(%{why: choice.why, utility: choice.utility})
  end

  defp abandon(region, body, outcome, reason) do
    plan = region |> Region.get(body, :autopilot) |> Map.get(:plan)

    data = %{
      why: :plan_abandoned,
      entry: plan.entry,
      step_ref: plan.ref,
      outcome: outcome,
      reason: reason
    }

    {drop_plan(region, body), Event.new(:decided, entity: body, data: data)}
  end

  defp drop_plan(region, body) do
    case Region.get(region, body, :autopilot) do
      %{plan: plan} = record when plan != nil ->
        Region.put_component(region, body, :autopilot, %{record | plan: nil})

      _no_plan ->
        region
    end
  end
end
