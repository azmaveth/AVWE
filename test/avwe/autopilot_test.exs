defmodule Avwe.AutopilotTest do
  @moduledoc """
  The brain and its system on the Ember Reach, stepped as a pure region:
  Mira's routine, its plans and their windows, takeovers, the jitter, the
  invited fire, warmth at night, rest, control and determinism. Sessions
  and the idle rule are in `test/e2e/autopilot_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Autopilot, Calendar, Event, Intent, Quire, Region, Worldgen}
  alias Avwe.Test.{Ember, Fixtures}

  @mira "mira-vale"
  @hearth "town-hearth"
  @lodge_hearth "lodge-hearth"
  @day Calendar.day()
  @entries 4

  # Steps a region one step at a time, keeping each step's events.
  defp run(region, steps, dt \\ 60) do
    Enum.map_reduce(1..steps, region, fn _n, acc ->
      {events, acc} = acc |> Region.advance(1, dt: dt) |> Region.drain_events()
      {{acc, events}, acc}
    end)
  end

  defp events(trace), do: Enum.flat_map(trace, fn {_region, events} -> events end)
  defp decided(events), do: for(%Event{type: :decided, data: data} <- events, do: data)
  defp intent_refs(events), do: for(%{intent_ref: ref} <- decided(events), do: ref)

  # When each decision was made.
  defp decided_at(events),
    do: for(%Event{type: :decided, data: data, time: time} <- events, do: {data, time})

  defp results(events), do: for(%Event{type: :action_result, data: data} <- events, do: data)
  defp of(events, type), do: Enum.filter(events, &(&1.type == type))

  # The routine steps decided, as `{entry, step}`, in order.
  defp routine_steps(events),
    do: for(%{why: :routine, entry: entry, step: step} <- decided(events), do: {entry, step})

  # The region in `trace` whose time is `{hour, minute}` of its day.
  defp at(trace, hour, minute) do
    Enum.find_value(trace, fn {region, _events} ->
      %{hour: h, minute: m} = Calendar.describe(region.time)
      if {h, m} == {hour, minute}, do: region
    end)
  end

  # Every region in `trace` from `{h1, m1}` to `{h2, m2}` of the day.
  defp between(trace, from, to) do
    for {region, _events} <- trace,
        %{hour: hour, minute: minute} = Calendar.describe(region.time),
        {hour, minute} >= from and {hour, minute} <= to,
        do: {region, {hour, minute}}
  end

  defp position(region, body \\ @mira), do: Region.get(region, body, :position)
  defp action(region, body \\ @mira), do: Region.get(region, body, :action)
  defp record(region, body \\ @mira), do: Region.get(region, body, :autopilot)

  defp at_place?(region, place, body \\ @mira),
    do: Avwe.Space.distance(position(region, body), Region.get(region, place, :position)) <= 2

  defp departures(events, body \\ @mira) do
    for %Event{type: :departed, entity: ^body, time: time} <- events,
        do: Calendar.describe(time)
  end

  defp arrivals(events, place, body \\ @mira) do
    for %Event{type: :arrived, entity: ^body, data: %{place: ^place}, time: time} <- events,
        do: Calendar.describe(time)
  end

  # When the body arrived at `place`, as times.
  defp arrival_times(events, place, body \\ @mira) do
    for %Event{type: :arrived, entity: ^body, data: %{place: ^place}, time: time} <- events,
        do: time
  end

  defp day_number(region), do: Integer.floor_div(region.time, @day)

  defp tick(region, dt \\ 60),
    do: %Avwe.Tick{
      step: region.step,
      time: region.time,
      dt: dt,
      seed: region.seed,
      region: region.id
    }

  # Mira's routine offset on the day `time` falls in.
  defp jitter(region, time),
    do: Autopilot.jitter(%{tick(region) | time: time}, [@mira])[@mira]

  defp candidates(region, body \\ @mira),
    do: Autopilot.candidates(region, tick(region), body, record(region, body))

  defp whys(region), do: region |> candidates() |> Enum.map(& &1.why)

  # Steps `region` up to `{hour, minute}` of its day.
  defp run_to(region, hour, minute) do
    %{hour: h, minute: m} = Calendar.describe(region.time)
    run(region, (hour - h) * 60 + (minute - m))
  end

  # Mira controlled from `region` for one `wait` of sixty seconds, as a
  # player would, and held until `fun` says otherwise.
  defp taken(region) do
    region
    |> Ember.controlled(@mira, :human)
    |> Region.submit(Intent.new(@mira, :wait, ref: "w", controller: :human, params: %{for: 60}))
  end

  defp released(region, body \\ @mira),
    do: Region.put_component(region, body, :control, %{holder: nil, since: region.time})

  # A controller takes the body for one step and has it light `hearth`
  # where it stands, then lets it go: the fire is lit by a journaled intent,
  # as a player would, not by hand.
  defp kindled(region, hearth) do
    region
    |> Ember.controlled(@mira, :human)
    |> Region.submit(Intent.new(@mira, :kindle, ref: "k", controller: :human, target: hearth))
    |> Region.advance(1)
    |> released()
  end

  describe "Mira's routine" do
    setup do
      {trace, _final} = Ember.region({813, day: 220, hour: 4}) |> run(1440)
      %{trace: trace, events: events(trace)}
    end

    test "walks the banks before dawn, warms her hands at the lodge, rests at home", %{
      trace: trace,
      events: events
    } do
      # Left by 04:40 (the step after 04:30, plus up to five minutes of
      # jitter) and at the bend by 05:00, where she waits forty minutes
      # before walking back: home by 05:40.
      left = at(trace, 4, 40)
      assert position(left) != Ember.places().town or match?(%{verb: :go}, action(left))
      assert [%{hour: 4}] = arrivals(events, "the-dry-bend") |> Enum.take(1)

      for {region, moment} <- between(trace, {4, 50}, {5, 10}) do
        assert at_place?(region, "the-dry-bend"), "not at the bend at #{inspect(moment)}"
      end

      assert at_place?(at(trace, 5, 40), "ember-reach")

      # At the lodge from 18:10 to 19:25, the ninety minutes by the Last
      # Coal, and home by 19:45; resting by 22:10.
      for {region, moment} <- between(trace, {18, 10}, {19, 25}) do
        assert at_place?(region, "ashwarden-lodge"), "not at the lodge at #{inspect(moment)}"
      end

      assert at_place?(at(trace, 19, 45), "ember-reach")

      resting = at(trace, 22, 10)
      assert at_place?(resting, "ember-reach")
      assert %{verb: :wait, params: %{until: :dawn}} = action(resting)

      # Every plan ran to its end, step by step: the rest entry's `go` home
      # found her there already.
      assert routine_steps(events) ==
               [
                 {0, 0},
                 {0, 1},
                 {0, 2},
                 {1, 0},
                 {1, 1},
                 {1, 2},
                 {2, 0},
                 {2, 1},
                 {2, 2},
                 {3, 0},
                 {3, 1}
               ]

      assert [%{verb: :go, target: "ember-reach", reason: :already_there}] =
               results(events) |> Enum.filter(&(&1.reason == :already_there))

      refute Enum.any?(decided(events), &(&1.why == :plan_abandoned))
    end

    test "fires each entry once a day, naming it", %{trace: trace, events: events} do
      {final, _events} = List.last(trace)
      day = day_number(at(trace, 12, 0))

      assert record(final).done == Map.new(0..(@entries - 1), &{&1, day})

      starts = for %{why: :routine, step: 0} = data <- decided(events), do: data
      assert Enum.map(starts, & &1.entry) == Enum.to_list(0..(@entries - 1))

      assert Enum.map(starts, & &1.note) == [
               "walks the banks before dawn",
               "the survey",
               "warms her hands at the lodge on the way home",
               nil
             ]

      assert Enum.all?(intent_refs(events), &String.starts_with?(&1, "auto-mira-vale-"))

      # The rest entry found her resting already: its `go` home replaced
      # that wait and succeeded on the spot, and the rest began again.
      assert for(%{adopted: _ref} = data <- decided(events), do: data) == []

      # Still on the last entry's plan at 04:00: resting until dawn, with
      # the dawn its wait ends at written in the plan.
      assert %{
               why: :routine,
               current: 0.6,
               plan: %{entry: 3, step: 1, steps: [], ref: "auto-" <> _, until: until}
             } = record(final)

      assert %{verb: :wait, until: ^until} = action(final)
      assert %{hour: 6, minute: 0} = Calendar.describe(until)
      refute Enum.any?(decided(events), &(&1.why == :missed))
    end

    test "no routine leads to the source", %{trace: trace, events: events} do
      {final, _events} = List.last(trace)
      refute "river-source" in Region.get(final, @mira, :knows)
      assert events |> of(:discovered) |> Enum.filter(&(&1.entity == @mira)) == []
    end

    test "every intent it submits ends in exactly one result", %{trace: trace, events: events} do
      # Except the ones not yet applied, or still running, at the end.
      {final, _events} = List.last(trace)
      pending = final |> Region.pending() |> Enum.map(& &1.ref)
      running = if action = action(final), do: [action.ref], else: []
      decided = intent_refs(events)

      assert results(events) |> Enum.map(& &1.ref) |> Enum.sort() ==
               Enum.sort(decided -- (pending ++ running))

      assert Enum.all?(Region.pending(final), &(&1.controller == :autopilot))
    end
  end

  describe "plans" do
    @bend [{:go, target: "the-dry-bend"}]

    test "two entries ten minutes apart in one long step: the last is taken, the first missed" do
      region =
        Ember.region()
        |> Region.put_component(@mira, :routine, [
          %{at: 4 * 3600 + 30 * 60, do: @bend, note: "first"},
          %{at: 4 * 3600 + 40 * 60, do: [{:go, target: "ashwarden-lodge"}], note: "last"}
        ])

      {[{after_step, events}], _final} = run(region, 1, 3600)
      day = day_number(after_step)

      assert [%{why: :missed, entry: 0, note: "first"}, %{why: :routine, entry: 1, note: "last"}] =
               decided(events)

      assert %{done: %{0 => ^day, 1 => ^day}} = record(after_step)
      assert [%{verb: :go, target: "ashwarden-lodge"}] = Region.pending(after_step)
    end

    test "an entry missed under a controller fires at the next decision point" do
      # Mira is played straight through 04:30 and given back at 04:45.
      {trace, held} = Ember.region() |> Ember.controlled(@mira, :human) |> run(45)
      assert decided(events(trace)) == []

      {trace, _final} = held |> released() |> run(2)

      assert [%{why: :routine, entry: 0, step: 0, note: "walks the banks before dawn"}] =
               decided(events(trace))

      assert %{verb: :go, target: "the-dry-bend"} = action(elem(List.last(trace), 0))
    end

    test "a blocked step abandons the plan, which is not retried that day" do
      region =
        Ember.region()
        |> Region.put_component(@mira, :routine, [
          %{at: 4 * 3600 + 30 * 60, do: [{:go, target: "nowhere"} | @bend], note: "lost"}
        ])

      {trace, final} = run(region, 3 * 60)
      events = events(trace)

      # Resting at 04:00; the plan's first step is refused the step after it
      # is taken, which ends the plan; the rest goes on until dawn.
      assert [
               %{why: :rest},
               %{why: :routine, entry: 0, step: 0, intent_ref: ref},
               %{
                 why: :plan_abandoned,
                 entry: 0,
                 step_ref: ref,
                 outcome: :blocked,
                 reason: :unknown_place
               },
               %{why: :idle} | later
             ] = decided(events)

      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned]))
      assert arrivals(events, "the-dry-bend") == []
      assert %{done: %{0 => _day}, plan: nil} = record(final)
    end

    test "an entry whose first step is a rest adopts a rest already begun instead of starting it again" do
      # Dark at 20:00, she rests; at 22:00 an entry of one rest finds her at it.
      region = Ember.region({813, day: 220, hour: 20})

      region =
        region
        |> Region.put_component(@mira, :autopilot, %{
          Autopilot.fresh()
          | done: %{0 => day_number(region) - 1}
        })
        |> Region.put_component(@mira, :routine, [%{at: 22 * 3600, do: {:rest}, note: nil}])

      {trace, final} = run_to(region, 22, 10)
      events = events(trace)

      assert [%{why: :rest, intent_ref: ref}, %{why: :routine, entry: 0, step: 0, adopted: ref}] =
               decided(events)

      assert results(events) == []
      assert %{verb: :wait, params: %{until: :dawn}, ref: ^ref, until: until} = action(final)
      assert %{plan: %{entry: 0, step: 0, steps: [], ref: ^ref, until: ^until}} = record(final)
      assert %{hour: 6, minute: 0} = Calendar.describe(until)
    end

    test "the rest entry takes her home first, then rests: given back at the bend after 22:00 she ends at home" do
      # Played at the bend through 22:00 and given back at 22:10, in the dark.
      {_trace, held} =
        {813, day: 220, hour: 21}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().dry_bend)
        |> Ember.controlled(@mira, :human)
        |> run_to(22, 10)

      {trace, final} = held |> released() |> run(60)
      events = events(trace)

      assert [%{why: :routine, entry: 3, step: 0}, %{why: :routine, entry: 3, step: 1} | later] =
               decided(events)

      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))
      assert [_home] = arrivals(events, "ember-reach")
      assert at_place?(final, "ember-reach")
      assert %{verb: :wait, params: %{until: :dawn}} = action(final)
    end

    test "a routine entry that comes due while a plan waits supersedes it, and says so" do
      # A three-hour watch from noon, and an entry at 14:00 that cuts it.
      region = Ember.region({813, day: 220, hour: 12})
      yesterday = day_number(region) - 1

      region =
        region
        |> Region.put_component(@mira, :autopilot, %{
          Autopilot.fresh()
          | done: %{0 => yesterday, 1 => yesterday}
        })
        |> Region.put_component(@mira, :routine, [
          %{
            at: 12 * 3600 - 5 * 60,
            do: [{:wait, params: %{for: 3 * 3600}}, {:go, target: "the-dry-bend"}],
            note: "a watch"
          },
          %{at: 14 * 3600, do: [{:go, target: "ashwarden-lodge"}], note: "the lodge"}
        ])

      {trace, _final} = run_to(region, 14, 30)
      events = events(trace)

      assert [
               %{why: :routine, entry: 0, step: 0, intent_ref: ref},
               %{
                 why: :plan_abandoned,
                 entry: 0,
                 step_ref: ref,
                 outcome: nil,
                 reason: :superseded
               },
               %{why: :routine, entry: 1, step: 0} | later
             ] = decided(events)

      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))

      assert [%{ref: ^ref, verb: :wait, outcome: :interrupted, reason: :replaced}] =
               Enum.filter(results(events), &(&1.ref == ref))

      assert [_lodge] = arrivals(events, "ashwarden-lodge")
      assert arrivals(events, "the-dry-bend") == []
    end

    test "the night's rest does not lock out the walk at dawn: she leaves on day two as on day one" do
      region = Ember.region()
      {trace, _final} = run(region, 2 * 1440)
      events = events(trace)
      day_two = region.time + @day

      # Decided on the minute of the entry's occurrence, and off at once: a
      # departure is stamped when the go begins, at the start of the next step.
      expected = day_number(region) * @day + @day + 4 * 3600 + 30 * 60 + jitter(region, day_two)

      [left | _later] =
        for %Event{type: :departed, entity: @mira, time: time} <- events,
            time >= day_two,
            do: time

      assert left == expected
      assert %{hour: 4, minute: minute} = Calendar.describe(left)
      assert minute in 25..36

      assert Enum.count(routine_steps(events), &(&1 == {0, 0})) == 2
      assert length(arrivals(events, "the-dry-bend")) == 4

      # The walk supersedes the night's rest, the only plan ever cut.
      assert [%{why: :plan_abandoned, entry: 3, outcome: nil, reason: :superseded}] =
               Enum.filter(decided(events), &(&1.why in [:plan_abandoned, :missed]))
    end

    test "by the hour too, day two begins like day one" do
      region = Ember.region()
      {trace, _final} = run(region, 48, 3600)
      events = events(trace)

      assert [_day_one, _day_two] =
               for(%{why: :routine, entry: 0, step: 0} = data <- decided(events), do: data)

      day_two = region.time + @day
      left = for %Event{type: :departed, entity: @mira, time: time} <- events, do: time
      [first | _rest] = Enum.filter(left, &(&1 < day_two))
      [second | _rest] = Enum.filter(left, &(&1 >= day_two))
      assert second == first + @day
      assert length(arrivals(events, "the-dry-bend")) == 4
    end
  end

  describe "takeovers" do
    # Mira at the bend in the survey's wait, around 08:30.
    defp surveying do
      {_trace, waiting} = Ember.region() |> run_to(8, 30)
      assert at_place?(waiting, "the-dry-bend")
      assert %{verb: :wait, ref: ref} = action(waiting)
      assert %{plan: %{entry: 1, step: 1, steps: [_home], ref: ^ref}} = record(waiting)
      waiting
    end

    test "a plan survives a short takeover: the pending wait is issued again for what is left of it" do
      waiting = surveying()
      assert %{plan: %{entry: 1, step: 1, until: until}} = record(waiting)
      assert %{verb: :wait, until: ^until} = action(waiting)

      {[{held, events}, {done, _events}], _final} = waiting |> taken() |> run(2)
      assert [%{ref: "w", outcome: :success}] = results(events) |> Enum.filter(&(&1.ref == "w"))
      assert decided(events) == []
      assert %{plan: %{entry: 1, step: 1, until: ^until}} = record(held)
      assert action(done) == nil

      # Her own again, she waits the rest of her three hours and comes home
      # when she would have.
      {trace, final} = done |> released() |> run_to(13, 0)
      events = events(trace)

      assert [
               %{why: :routine, entry: 1, step: 1, intent_ref: ref},
               %{why: :routine, entry: 1, step: 2} | later
             ] = decided(events)

      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))

      assert [%{ref: ^ref, verb: :wait, params: %{for: left}, outcome: :success}] =
               Enum.filter(results(events), &(&1.ref == ref))

      assert left == until - (done.time + 60)
      assert [home] = arrival_times(events, "ember-reach")
      {baseline, _final} = Ember.region() |> run_to(13, 0)
      assert home == baseline |> events() |> arrival_times("ember-reach") |> List.last()

      assert at_place?(final, "ember-reach")
      assert %{plan: nil} = record(final)
    end

    test "a two-minute takeover at the bend during the walk's wait costs her no more than those minutes" do
      {baseline, _final} = Ember.region() |> run_to(6, 0)
      [home] = arrival_times(events(baseline), "ember-reach")

      {_trace, waiting} = Ember.region() |> run_to(5, 0)
      assert at_place?(waiting, "the-dry-bend")
      assert %{plan: %{entry: 0, step: 1, until: until}} = record(waiting)
      assert %{verb: :wait, until: ^until, params: %{for: 2400}} = action(waiting)

      {_trace, held} = waiting |> taken() |> run(2)
      {trace, _final} = held |> released() |> run_to(6, 0)
      events = events(trace)

      assert [
               %{why: :routine, entry: 0, step: 1, intent_ref: ref},
               %{why: :routine, entry: 0, step: 2} | _later
             ] = decided(events)

      assert [%{ref: ^ref, params: %{for: left}}] = Enum.filter(results(events), &(&1.ref == ref))
      assert left == until - (held.time + 60)
      assert left < 2400

      assert [back] = arrival_times(events, "ember-reach")
      assert (back - home) in 0..240
    end

    test "a takeover that moves her to the lodge during the bend wait resumes with the next step" do
      moved =
        surveying()
        |> Ember.controlled(@mira, :human)
        |> Region.submit(
          Intent.new(@mira, :go, ref: "g", controller: :human, target: "ashwarden-lodge")
        )

      {_trace, held} = run(moved, 25)
      assert at_place?(held, "ashwarden-lodge")
      assert %{plan: %{entry: 1, step: 1}} = record(held)

      {trace, final} = held |> released() |> run(30)
      events = events(trace)

      assert [%{why: :routine, entry: 1, step: 2} | later] = decided(events)
      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))
      assert [_home] = arrivals(events, "ember-reach")
      assert arrivals(events, "the-dry-bend") == []
      assert at_place?(final, "ember-reach")
      assert %{plan: nil} = record(final)
    end

    test "sent to the lodge from the survey's wait and let go on the way, she finishes the walk, then goes home" do
      # Away from the bend the pending wait is off course, so the plan skips
      # to its walk home, which waits for the journey to end as any routine
      # step does.
      {_trace, walking} =
        surveying()
        |> Ember.controlled(@mira, :human)
        |> Region.submit(
          Intent.new(@mira, :go, ref: "g", controller: :human, target: "ashwarden-lodge")
        )
        |> run(5)

      assert %{verb: :go, ref: "g"} = action(walking)
      refute at_place?(walking, "the-dry-bend")
      assert %{plan: %{entry: 1, step: 1}} = record(walking)

      {trace, final} = walking |> released() |> run_to(10, 0)
      events = events(trace)

      assert [%{why: :routine, entry: 1, step: 2} | later] = decided(events)
      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))
      assert [%{ref: "g", outcome: :success}] = Enum.filter(results(events), &(&1.ref == "g"))
      [lodge] = arrival_times(events, "ashwarden-lodge")
      [home] = arrival_times(events, "ember-reach")
      assert lodge < home
      assert arrivals(events, "the-dry-bend") == []
      assert at_place?(final, "ember-reach")
      assert %{plan: nil} = record(final)
    end

    test "moved off her night's rest and let go away from home, she skips it: from the docks she goes home, by the Last Coal she keeps her place" do
      # Resting at home at 22:30, taken and sent somewhere, let go there at
      # 23:00 with the rest step pending.
      {_trace, resting} = {813, day: 220, hour: 22} |> Ember.region() |> run_to(22, 30)
      assert %{plan: %{entry: 3, step: 1, until: until}} = record(resting)
      assert %{verb: :wait, params: %{until: :dawn}, until: ^until} = action(resting)

      sent = fn place ->
        {_trace, held} =
          resting
          |> Ember.controlled(@mira, :human)
          |> Region.submit(Intent.new(@mira, :go, ref: "g", controller: :human, target: place))
          |> run_to(23, 0)

        assert at_place?(held, place)
        assert action(held) == nil
        assert %{plan: %{entry: 3, step: 1}} = record(held)
        held |> released() |> run(60)
      end

      # The rest is skipped and the plan done; the dark takes her home, where
      # she rests, as it takes any body with nothing afoot.
      {trace, final} = sent.("willow-docks")
      events = events(trace)

      assert [%{why: :rest, utility: 0.55}, %{why: :rest, utility: 0.5} | later] =
               decided(events)

      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :missed]))
      assert [_home] = arrivals(events, "ember-reach")
      assert at_place?(final, "ember-reach")
      assert %{verb: :wait, params: %{until: :dawn}} = action(final)
      assert %{plan: nil} = record(final)

      # By the Last Coal, in the cold, she stays by the fire instead, half an
      # hour at a time: the rest step is not served there either.
      {trace, final} = sent.("ashwarden-lodge")
      events = events(trace)
      assert [%{why: :stay, utility: 0.6} | later] = decided(events)
      assert Enum.all?(later, &(&1.why == :stay))
      assert at_place?(final, "ashwarden-lodge")
      assert %{verb: :wait, params: %{for: 1800}} = action(final)
      assert %{plan: nil} = record(final)
    end

    test "held all day and let go by the Last Coal at 23:00, the rest entry still takes her home" do
      # Taken at 04:00, sent to the lodge at 05:00 and held there until
      # 23:00, in the dark and the cold by a fire: an hour of the day's last
      # entry is left, and it is never too late to start.
      {_trace, held} = Ember.region() |> Ember.controlled(@mira, :human) |> run_to(5, 0)

      {_trace, held} =
        held
        |> Region.submit(
          Intent.new(@mira, :go, ref: "g", controller: :human, target: "ashwarden-lodge")
        )
        |> run_to(23, 0)

      assert at_place?(held, "ashwarden-lodge")
      assert action(held) == nil
      assert :stay in whys(held)

      {trace, final} = held |> released() |> run(60)
      events = events(trace)

      assert [
               %{why: :missed, entry: 0, reason: :window_closed},
               %{why: :missed, entry: 1, reason: :window_closed},
               %{why: :missed, entry: 2, reason: :window_closed},
               %{why: :routine, entry: 3, step: 0},
               %{why: :routine, entry: 3, step: 1} | later
             ] = decided(events)

      refute Enum.any?(later, &(&1.why in [:stay, :routine, :plan_abandoned, :missed]))
      assert [_home] = arrivals(events, "ember-reach")
      assert at_place?(final, "ember-reach")
      assert %{verb: :wait, params: %{until: :dawn}} = action(final)
    end

    test "an entry with a twenty-minute window still starts when the body was busy at its occurrence" do
      # Two entries twenty minutes apart at noon; Mira held through the
      # first's occurrence and let go six minutes after it, with fourteen of
      # the twenty left: enough, since the margin is half a short window.
      region = Ember.region({813, day: 220, hour: 12})
      yesterday = day_number(region) - 1

      region =
        region
        |> Region.put_component(@mira, :autopilot, %{
          Autopilot.fresh()
          | done: %{0 => yesterday, 1 => yesterday}
        })
        |> Region.put_component(@mira, :routine, [
          %{at: 12 * 3600, do: [{:go, target: "willow-docks"}], note: "short"},
          %{at: 12 * 3600 + 20 * 60, do: [{:go, target: "ashwarden-lodge"}], note: "next"}
        ])

      minutes = 6 + div(jitter(region, region.time), 60)
      {trace, held} = region |> Ember.controlled(@mira, :human) |> run(minutes)
      assert decided(events(trace)) == []

      {trace, _final} = held |> released() |> run(2)

      assert [%{why: :routine, entry: 0, step: 0, note: "short"}] = decided(events(trace))
      assert %{verb: :go, target: "willow-docks"} = action(elem(List.last(trace), 0))
    end

    test "a plan whose window closed during the takeover is dropped" do
      {_trace, held} = surveying() |> taken() |> run_to(18, 30)
      assert %{plan: %{entry: 1, step: 1}} = record(held)

      {trace, final} = held |> released() |> run(100)
      events = events(trace)

      assert [
               %{why: :plan_abandoned, entry: 1, outcome: nil, reason: :window_closed},
               %{why: :routine, entry: 2, step: 0} | _later
             ] = decided(events)

      assert arrivals(events, "the-dry-bend") == []
      assert [_lodge] = arrivals(events, "ashwarden-lodge")
      assert at_place?(final, "ashwarden-lodge")
    end

    test "given back on a journey after a night held, she finishes the walk before her routine goes on" do
      # Taken at 22:30 on the night's rest, held to 06:15, sent to the lodge
      # and let go on the way: the rest's window has closed, and the walk
      # entry, due since 04:30, waits for the journey to end.
      {_trace, resting} = {813, day: 220, hour: 22} |> Ember.region() |> run_to(22, 30)
      assert %{plan: %{entry: 3, step: 1}} = record(resting)
      assert %{verb: :wait, params: %{until: :dawn}} = action(resting)

      {_trace, held} = resting |> taken() |> run(7 * 60 + 45)
      assert %{hour: 6, minute: 15} = Calendar.describe(held.time)

      {_trace, walking} =
        held
        |> Region.submit(
          Intent.new(@mira, :go, ref: "g", controller: :human, target: "ashwarden-lodge")
        )
        |> run(3)

      assert %{verb: :go, ref: "g"} = action(walking)

      {trace, _final} = walking |> released() |> run_to(7, 30)
      events = events(trace)

      assert [
               %{why: :plan_abandoned, entry: 3, outcome: nil, reason: :window_closed},
               %{why: :routine, entry: 0, step: 0} | _later
             ] = decided(events)

      assert [%{ref: "g", outcome: :success}] = Enum.filter(results(events), &(&1.ref == "g"))
      [lodge] = arrival_times(events, "ashwarden-lodge")
      [bend] = arrival_times(events, "the-dry-bend")
      assert lodge < bend
    end

    test "a wait a controller left her in is cut by the next entry on time" do
      {_trace, idle} = Ember.region() |> run_to(7, 0)

      held =
        idle
        |> Ember.controlled(@mira, :human)
        |> Region.submit(
          Intent.new(@mira, :wait, ref: "w", controller: :human, params: %{for: 3 * 3600})
        )

      {_trace, held} = run(held, 2)
      assert %{verb: :wait, ref: "w"} = action(held)

      {trace, _final} = held |> released() |> run_to(8, 15)
      events = events(trace)

      assert [%{why: :routine, entry: 1, step: 0} | _later] = decided(events)

      assert [%{ref: "w", outcome: :interrupted, reason: :replaced}] =
               Enum.filter(results(events), &(&1.ref == "w"))

      day_start = day_number(held) * @day
      [left] = for %Event{type: :departed, entity: @mira, time: time} <- events, do: time
      assert left == day_start + 8 * 3600 + jitter(held, held.time)
    end

    test "given back at 07:30, too late for the walk, she waits for the survey" do
      {_trace, held} = Ember.region() |> Ember.controlled(@mira, :human) |> run_to(7, 30)
      {trace, _final} = held |> released() |> run_to(8, 30)
      events = events(trace)

      assert [
               %{why: :missed, entry: 0, reason: :too_late, note: "walks the banks before dawn"},
               %{why: :idle, utility: 0.1},
               %{why: :routine, entry: 1, step: 0} | _later
             ] = decided(events)

      day_start = day_number(held) * @day
      [left] = for %Event{type: :departed, entity: @mira, time: time} <- events, do: time
      assert left == day_start + 8 * 3600 + jitter(held, held.time)
    end

    test "released at 17:00, the survey's wait is long over: she comes home, and the lodge entry runs on time" do
      {_trace, held} = surveying() |> taken() |> run_to(17, 0)
      {trace, _final} = held |> released() |> run_to(18, 40)
      events = events(trace)

      assert [
               %{why: :routine, entry: 1, step: 2},
               %{why: :idle, utility: 0.1},
               %{why: :routine, entry: 2, step: 0} | _rest
             ] = decided(events)

      day_start = day_number(held) * @day
      [_home, lodge] = for %Event{type: :departed, entity: @mira, time: time} <- events, do: time
      assert lodge == day_start + 18 * 3600 + jitter(held, held.time)
      assert [_home] = arrivals(events, "ember-reach")
      refute Enum.any?(decided(events), &(&1.why in [:plan_abandoned, :missed]))
    end

    test "released late in the day, she runs only the entry still in its window" do
      {_trace, held} = Ember.region() |> Ember.controlled(@mira, :human) |> run_to(18, 30)
      {trace, _final} = held |> released() |> run(4 * 60)
      events = events(trace)

      assert [
               %{why: :missed, entry: 0, note: "walks the banks before dawn"},
               %{why: :missed, entry: 1, note: "the survey"},
               %{why: :routine, entry: 2, step: 0} | _later
             ] = decided(events)

      assert arrivals(events, "the-dry-bend") == []
      assert [_lodge] = arrivals(events, "ashwarden-lodge")
    end
  end

  describe "windows" do
    @late [%{at: 23 * 3600 + 30 * 60, do: [{:wait, params: %{for: 600}}], note: "late"}]

    test "an entry at 23:30 fires once each day, by the minute" do
      region = Ember.region() |> Region.put_component(@mira, :routine, @late)
      {trace, final} = run(region, 2 * 1440)
      events = events(trace)

      expected =
        for day <- [region.time, region.time + @day],
            do: Integer.floor_div(day, @day) * @day + 23 * 3600 + 30 * 60 + jitter(region, day)

      assert for({%{why: :routine, entry: 0}, time} <- decided_at(events), do: time) == expected
      refute Enum.any?(decided(events), &(&1.why == :missed))
      assert %{done: %{0 => day}} = record(final)
      assert day == day_number(region) + 1
    end

    test "an entry at 23:30 fires once each day, by the hour" do
      region = Ember.region() |> Region.put_component(@mira, :routine, @late)
      {trace, _final} = run(region, 48, 3600)
      events = events(trace)

      # Found by the step that ends on the stroke of midnight.
      assert [first, second] =
               for({%{why: :routine, entry: 0}, time} <- decided_at(events), do: time)

      assert %{hour: 0, minute: 0} = Calendar.describe(first)
      assert second == first + @day
      refute Enum.any?(decided(events), &(&1.why == :missed))
    end

    test "an entry jittered past midnight is still that day's, and fires once a day" do
      # A day on which Mira's offset carries a late entry past midnight, and
      # the next day's offset is smaller, so the two occurrences fall on
      # either side of it.
      {region, offset} =
        Enum.find_value(220..300, fn day ->
          region = Ember.region({813, day: day, hour: 4})
          offset = jitter(region, region.time)
          if offset >= 120 and jitter(region, region.time + @day) < offset, do: {region, offset}
        end)

      at = @day - offset + 60

      region =
        Region.put_component(region, @mira, :routine, [
          %{at: at, do: [{:wait, params: %{for: 600}}], note: nil}
        ])

      {trace, final} = run(region, 2 * 1440)
      events = events(trace)
      day_start = day_number(region) * @day

      expected = [
        day_start + @day + 60,
        day_start + @day + at + jitter(region, region.time + @day)
      ]

      assert for({%{why: :routine, entry: 0}, time} <- decided_at(events), do: time) == expected
      refute Enum.any?(decided(events), &(&1.why == :missed))
      assert %{done: %{0 => day}} = record(final)
      assert day == day_number(region) + 1
    end
  end

  describe "jitter" do
    test "is the same in two builds, within five minutes, and differs between bodies" do
      departure = fn region ->
        {trace, _final} = run(region, 70)
        [first | _rest] = trace |> events() |> departures()
        first
      end

      first = departure.(Ember.region())
      assert first == departure.(Ember.region())
      assert first.hour == 4 and first.minute in 25..36

      # A second body with Mira's routine, built by hand at her home.
      region = Ember.region()
      mira = Region.entity(region, @mira)

      twin =
        region
        |> Region.put_entity("tam", Map.take(mira, [:body, :knows, :home, :position, :routine]))
        |> Region.put_entity("tam", %{
          repr: %{name: "Tam", description: nil},
          autopilot: Autopilot.fresh(),
          control: %{holder: nil, since: nil}
        })

      {trace, _final} = run(twin, 70)
      [mira_left | _rest] = trace |> events() |> departures(@mira)
      [tam_left | _rest] = trace |> events() |> departures("tam")
      assert mira_left == first
      assert tam_left.minute in 25..36
      assert tam_left != mira_left
    end

    test "comes from the tick's random stream, per body per day" do
      tick = %Avwe.Tick{
        step: 0,
        time: Calendar.at(813, day: 220, hour: 4),
        dt: 60,
        seed: 1,
        region: {0, 0}
      }

      later = %{tick | time: Calendar.at(813, day: 220, hour: 17), step: 780}

      jitter = Autopilot.jitter(tick, [@mira, "tam"])
      assert jitter == Autopilot.jitter(later, [@mira, "tam"])
      assert Enum.all?(jitter, fn {_body, s} -> rem(s, 60) == 0 and abs(s) <= 300 end)

      next_day = %{tick | time: Calendar.at(813, day: 221, hour: 4)}
      assert Autopilot.jitter(next_day, [@mira, "tam"]) != jitter
      assert Autopilot.jitter(%{tick | seed: 2}, [@mira, "tam"]) != jitter
    end

    test "is each body's own: adding bodies never shifts another's offset" do
      tick = %Avwe.Tick{
        step: 0,
        time: Calendar.at(813, day: 220, hour: 4),
        dt: 60,
        seed: 1,
        region: {0, 0}
      }

      alone = Autopilot.jitter(tick, [@mira])[@mira]

      for n <- 1..5 do
        others = Enum.map(1..n, &"a#{&1}")
        assert Autopilot.jitter(tick, others ++ [@mira])[@mira] == alone
        assert Autopilot.jitter(tick, [@mira | others])[@mira] == alone
      end
    end
  end

  describe "the invited fire" do
    # The air is at its coldest before dawn (it never falls below 13 °C in
    # this weather, and is "cool" below 15 °C from about 20:20 to 06:57), so
    # the cold night is 03:00. The river bed beside the town is 33 °C in
    # 812 and 17 °C in 813 at that hour.
    test "in 812 Mira lights her hearth within ten minutes of a cold night" do
      region = Ember.region({812, day: 199, hour: 3})
      assert region.env.air_c < Autopilot.cold_c()
      assert Autopilot.invited?(region, @hearth)

      {trace, final} = run(region, 10)
      assert [%Event{entity: @hearth, data: %{by: @mira}}] = trace |> events() |> of(:fire_lit)
      assert [%{why: :kindle, utility: 0.8} | _rest] = trace |> events() |> decided()
      assert Region.get(final, @hearth, :hearth).burning
    end

    test "in 813, keeping the Compact, she leaves it cold all night" do
      region = Ember.region({813, day: 220, hour: 3})
      assert region.env.air_c < Autopilot.cold_c()
      refute Autopilot.invited?(region, @hearth)
      assert Region.get(region, @mira, :norms) == [:invited_fire]

      {trace, final} = run(region, 4 * 60)
      assert trace |> events() |> of(:fire_lit) == []

      refute Enum.any?(trace, fn {region, _events} ->
               Region.get(region, @hearth, :hearth).burning
             end)

      assert Region.get(final, @hearth, :hearth).fuel_kg == 8.0
      assert [%{why: :rest} | _rest] = trace |> events() |> decided()
    end

    test "without the norm she lights it anyway" do
      region =
        {813, day: 220, hour: 3} |> Ember.region() |> Region.put_component(@mira, :norms, [])

      {trace, _final} = run(region, 10)
      assert [%Event{entity: @hearth, data: %{by: @mira}}] = trace |> events() |> of(:fire_lit)
    end
  end

  describe "warmth at night" do
    test "by a lit hearth on a cold night she stays by the fire until her routine takes her home" do
      # 21:00 on a cold 813 night, Mira at the lodge, whose hearth a player
      # has just lit for her. Until 22:00 she neither sets off home nor
      # turns back for the warmth: she keeps her place. Then the rest entry
      # takes her home, as it would from anywhere, and she rests there.
      region =
        {813, day: 220, hour: 21}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().lodge)
        |> kindled(@lodge_hearth)

      assert Region.get(region, @lodge_hearth, :hearth).burning
      assert region.env.air_c < Autopilot.cold_c()

      {trace, final} = run(region, 3 * 60)
      events = events(trace)

      for {region, moment} <- between(trace, {21, 1}, {21, 50}) do
        assert at_place?(region, "ashwarden-lodge"), "not at the lodge at #{inspect(moment)}"
      end

      assert [%{hour: hour, minute: minute}] = departures(events)
      assert {hour, minute} >= {21, 55}
      assert [_home] = arrivals(events, "ember-reach")
      assert at_place?(final, "ember-reach")

      {stays, [home, rest | later]} = events |> decided() |> Enum.split_while(&(&1.why == :stay))
      assert stays != []
      assert Enum.all?(stays, &(&1.utility == 0.6))
      assert %{why: :routine, entry: 3, step: 0} = home
      assert %{why: :routine, entry: 3, step: 1} = rest
      refute Enum.any?(later, &(&1.why in [:routine, :plan_abandoned, :fire]))

      waits = for %{ref: "auto-" <> _step, verb: :wait} = result <- results(events), do: result
      assert Enum.all?(waits, &(&1.params == %{for: 1800}))
      assert %{verb: :wait, params: %{until: :dawn}} = action(final)
    end

    test "on a cool morning with the hearth lit she still walks the banks and surveys" do
      # 812, the hearth lit at 04:01: the fire behind her as she sets out
      # never calls her back, and both plans run to their end.
      {trace, _final} =
        {812, day: 199, hour: 4} |> Ember.region() |> kindled(@hearth) |> run(8 * 60)

      events = events(trace)

      assert [%{hour: 4}, %{hour: 8}] = arrivals(events, "the-dry-bend")
      assert [%{hour: 5}, %{hour: 11}] = arrivals(events, "ember-reach")

      assert routine_steps(events) == [{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}]
      refute Enum.any?(decided(events), &(&1.why in [:plan_abandoned, :fire, :kindle]))

      # Home again before dawn, she sits by her fire.
      assert Enum.any?(decided(events), &(&1.why == :stay))
    end

    test "a fire in sight on a cold night draws her, when nothing else is afoot" do
      # 21:00, the lodge hearth burning and Mira 120 m east of it, in the
      # dark: she goes to it rather than home, then stays by it.
      {x, y} = Ember.places().lodge
      region = Ember.region({813, day: 220, hour: 21})
      hearth = Region.get(region, @lodge_hearth, :hearth)

      region =
        region
        |> Region.put_component(@mira, :position, {x + 12, y})
        |> Region.put_component(@lodge_hearth, :hearth, %{
          hearth
          | burning: true,
            lit_at: region.time
        })

      {trace, final} = run(region, 10)
      events = events(trace)

      assert [%{why: :fire, utility: 0.7}, %{why: :stay} | _rest] = decided(events)
      assert %{verb: :go, target: "ashwarden-lodge"} = action(elem(Enum.at(trace, 1), 0))
      assert [_arrived] = arrivals(events, "ashwarden-lodge")
      assert at_place?(final, "ashwarden-lodge")
    end
  end

  describe "the conditions" do
    # 21:00 on a cold 813 night, Mira 120 m east of `place`, whose hearth
    # burns in the dark.
    defp fire_east_of(place, hearth) do
      {x, y} = Ember.places()[place]
      region = Ember.region({813, day: 220, hour: 21})
      burning = Region.get(region, hearth, :hearth)

      region
      |> Region.put_component(@mira, :position, {x + 12, y})
      |> Region.put_component(hearth, :hearth, %{burning | burning: true, lit_at: region.time})
    end

    # A routine of one entry, done for yesterday (as `prepare/1` would have
    # it) and due whatever the jitter at the first step after `at` plus five
    # minutes: a wait of `seconds`, then a walk to `place`.
    defp watch(region, at, seconds, place) do
      region
      |> Region.put_component(@mira, :autopilot, %{
        Autopilot.fresh()
        | done: %{0 => day_number(region) - 1}
      })
      |> Region.put_component(@mira, :routine, [
        %{at: at, do: [{:wait, params: %{for: seconds}}, {:go, target: place}], note: "a watch"}
      ])
    end

    # A fire burning at Mira's own cell.
    defp camp_fire(region) do
      hearth = Region.get(region, @lodge_hearth, :hearth)

      Region.put_entity(region, "camp", %{
        hearth: %{hearth | burning: true, lit_at: region.time},
        position: position(region),
        repr: %{name: "a camp fire", description: nil}
      })
    end

    test "a running plan is not interrupted by a fire in sight" do
      {x, y} = Ember.places().town

      region =
        {813, day: 220, hour: 21}
        |> Ember.region()
        |> Region.put_component(@mira, :position, {x + 12, y})
        |> watch(21 * 3600 - 5 * 60, 3600, "ashwarden-lodge")

      # Decided in the first step, under way from the second.
      {trace, waiting} = run(region, 2)
      assert %{plan: %{entry: 0, step: 0, ref: ref}} = record(waiting)
      assert %{verb: :wait, ref: ^ref} = action(waiting)
      hearth = Region.get(waiting, @hearth, :hearth)

      lit =
        Region.put_component(waiting, @hearth, :hearth, %{
          hearth
          | burning: true,
            lit_at: waiting.time
        })

      assert :fire in whys(lit)

      {trace2, final} = run(lit, 65)
      events = events(trace ++ trace2)
      refute Enum.any?(decided(events), &(&1.why in [:fire, :plan_abandoned]))
      assert routine_steps(events) == [{0, 0}, {0, 1}]
      assert [%{ref: ^ref, verb: :wait, outcome: :success}] = results(events)
      assert %{verb: :go, target: "ashwarden-lodge"} = action(final)
    end

    test "going to a fire needs no fire felt where the body stands" do
      region = fire_east_of(:lodge, @lodge_hearth)

      assert [%{why: :fire, intent: {:go, target: "ashwarden-lodge"}} | _rest] =
               candidates(region)

      refute :stay in whys(region)

      warmed = camp_fire(region)
      refute :fire in whys(warmed)
      assert :stay in whys(warmed)
    end

    test "going home for the night needs no fire felt" do
      region = fire_east_of(:docks, @lodge_hearth)

      assert [%{why: :rest, utility: 0.55, intent: {:go, target: "ember-reach"}}, %{why: :idle}] =
               candidates(region)

      assert whys(camp_fire(region)) == [:stay, :idle]
    end

    test "staying by the fire needs the cold" do
      region =
        {813, day: 220, hour: 21}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().lodge)
        |> camp_fire()

      assert region.env.air_c < Autopilot.cold_c()
      assert :stay in whys(region)
      refute :stay in whys(Region.put_env(region, :air_c, 20.0))
    end

    test "kindling needs fuel" do
      region = Ember.region({812, day: 199, hour: 3})
      assert [%{why: :kindle, intent: {:kindle, target: @hearth}} | _rest] = candidates(region)

      hearth = Region.get(region, @hearth, :hearth)
      bare = Region.put_component(region, @hearth, :hearth, %{hearth | fuel_kg: 0.0})
      refute :kindle in whys(bare)
    end

    test "the kindle that cuts in does not end a plan" do
      region = Ember.region({812, day: 199, hour: 3})
      hearth = Region.get(region, @hearth, :hearth)

      region =
        region
        |> Region.put_component(@hearth, :hearth, %{hearth | fuel_kg: 0.0})
        |> watch(3 * 3600 - 5 * 60, 1800, "the-dry-bend")

      {trace, waiting} = run(region, 2)
      assert %{plan: %{entry: 0, step: 0, ref: ref}} = record(waiting)
      assert %{verb: :wait, ref: ^ref} = action(waiting)

      fuelled = Region.put_component(waiting, @hearth, :hearth, %{hearth | fuel_kg: 8.0})
      {trace2, final} = run(fuelled, 40)
      events = events(trace ++ trace2)

      # The walk after the half hour brings her to the bend, and the dark
      # then turns her home: the plan ran out, it was not cut short.
      assert [
               %{why: :routine, entry: 0, step: 0},
               %{why: :kindle},
               %{why: :routine, entry: 0, step: 1},
               %{why: :rest, utility: 0.55}
             ] = decided(events)

      assert [_bend] = arrivals(events, "the-dry-bend")
      assert [%Event{entity: @hearth, data: %{by: @mira}}] = of(events, :fire_lit)
      assert %{ref: ^ref} = action(elem(Enum.at(trace2, 3), 0))
      assert %{verb: :go, target: "ember-reach"} = action(final)
    end
  end

  describe "rest" do
    test "a body away from home at dark goes home" do
      region =
        {813, day: 220, hour: 20}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().dry_bend)

      # Decided in the first step, applied in the second; home, she rests.
      {trace, _final} = run(region, 12)

      assert [%{why: :rest, utility: 0.55}, %{why: :rest, utility: 0.5}] =
               trace |> events() |> decided()

      assert %{verb: :go, target: "ember-reach"} = action(elem(Enum.at(trace, 1), 0))
      assert at_place?(elem(List.last(trace), 0), "ember-reach")
    end

    test "by day, away from home with nothing to do, it goes home" do
      region =
        {813, day: 220, hour: 13}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().dry_bend)

      {trace, final} = run(region, 40)
      events = events(trace)

      assert [%{why: :idle, utility: 0.3}, %{why: :idle, utility: 0.1} | _rest] = decided(events)
      assert %{verb: :go, target: "ember-reach"} = action(elem(Enum.at(trace, 1), 0))
      assert [_home] = arrivals(events, "ember-reach")
      assert at_place?(final, "ember-reach")

      # Home by day with the lodge entry hours off, she waits the hour.
      assert %{verb: :wait, params: %{for: 3600}} = action(final)
    end

    test "an idle wait ends at the next routine occurrence of the day, or in an hour" do
      # Home at 07:00 after the walk, the survey at 08:00 is what comes next.
      {_trace, morning} = Ember.region() |> run_to(7, 0)

      [%{why: :idle, intent: {:wait, params: %{for: seconds}}}] =
        candidates(morning) |> Enum.filter(&(&1.why == :idle))

      day_start = day_number(morning) * @day
      assert morning.time + 60 + seconds == day_start + 8 * 3600 + jitter(morning, morning.time)

      # With nothing left in the day, an hour.
      {_trace, night} = Ember.region() |> run_to(23, 0)

      assert [%{why: :idle, intent: {:wait, params: %{for: 3600}}}] =
               candidates(Region.delete_component(night, @mira, :routine))
               |> Enum.filter(&(&1.why == :idle))
    end

    test "an idle day costs a handful of decisions" do
      {:ok, quire} = Quire.load(Fixtures.lantern_hollow())

      region =
        Worldgen.region(quire,
          id: {0, 0},
          seed: 1,
          time: Calendar.at(1, hour: 12),
          systems: Ember.region().systems
        )

      {trace, _final} = run(region, 1440)
      decisions = for %Event{type: :decided, entity: body} <- events(trace), do: body
      assert Enum.sort(Enum.uniq(decisions)) == ~w(odo pell tamsin wren)
      assert Enum.all?(Enum.frequencies(decisions), fn {_body, count} -> count <= 24 end)
    end

    test "at home it waits until dawn" do
      {trace, _final} = {813, day: 220, hour: 20} |> Ember.region() |> run(2)
      assert [%{why: :rest, utility: 0.5}] = trace |> events() |> decided()
      assert %{verb: :wait, params: %{until: :dawn}} = action(elem(Enum.at(trace, 1), 0))
    end

    test "at dawn the rest is over, not begun again" do
      # The light is still 0.0 at 06:00 itself, when the wait ends.
      {trace, _final} = {813, day: 220, hour: 5, minute: 50} |> Ember.region() |> run(12)
      [%{why: :rest} | later] = trace |> events() |> decided()
      assert [%{why: :idle} | _rest] = later
      refute Enum.any?(later, &(&1.why == :rest))
      assert [%{reason: :done, params: %{until: :dawn}}] = trace |> events() |> results()
    end

    test "a world begun in the evening did not miss the morning" do
      region = Ember.region({813, day: 220, hour: 18})
      day = day_number(region)
      assert %{done: %{0 => ^day, 1 => ^day}} = record(region)

      # The entry at the starting hour is still to come.
      {trace, _final} = run(region, 3)
      assert [%{why: :routine, entry: 2, step: 0}] = trace |> events() |> decided()
    end

    test "the Lantern Hollow bodies, with no routine, do nothing by day" do
      {:ok, quire} = Quire.load(Fixtures.lantern_hollow())

      region =
        Worldgen.region(quire,
          id: {0, 0},
          seed: 1,
          time: Calendar.at(1, hour: 12),
          systems: Ember.region().systems
        )

      {trace, final} = run(region, 60)
      events = events(trace)
      assert Enum.all?(decided(events), &(&1.why == :idle))
      assert Enum.all?(results(events), &(&1.verb == :wait and &1.params == %{for: 3600}))

      assert Enum.uniq(Enum.map(events, & &1.type)) -- [:decided, :action_started, :action_result] ==
               []

      for body <- ~w(wren tamsin pell odo) do
        assert position(final, body) == position(region, body)
      end
    end
  end

  describe "control" do
    test "a controlled body is left alone for a whole day, and resumes within a step of release" do
      region = Ember.region() |> Ember.controlled(@mira, :human)
      {trace, final} = run(region, 1440)

      assert trace |> events() |> decided() == []
      assert Region.pending(final) == []
      assert action(final) == nil
      assert position(final) == Ember.places().town

      {[{_region, events}], _final} = final |> released() |> run(1)

      assert [
               %{why: :missed, entry: 0},
               %{why: :missed, entry: 1},
               %{why: :missed, entry: 2},
               %{why: :missed, entry: 3},
               %{why: :rest}
             ] = decided(events)
    end
  end

  describe "determinism" do
    test "the same seed gives the same day, stepped one at a time or all at once" do
      one = Ember.region() |> Region.advance(1440)
      two = Ember.region() |> Region.advance(1440)
      assert Region.state_hash(one) == Region.state_hash(two)

      {_trace, stepped} = Ember.region() |> run(1440)
      assert Region.state_hash(stepped) == Region.state_hash(one)
    end

    test "in history mode, by the hour, she still visits each routine target" do
      {trace, _final} = Ember.region() |> run(24, 3600)
      events = events(trace)

      assert length(arrivals(events, "the-dry-bend")) == 2
      assert length(arrivals(events, "ashwarden-lodge")) == 1
      assert length(arrivals(events, "ember-reach")) == 3

      assert for(%{why: :routine, step: 0, entry: entry} <- decided(events), do: entry) ==
               Enum.to_list(0..(@entries - 1))

      refute Enum.any?(decided(events), &(&1.why == :plan_abandoned))
    end
  end
end
