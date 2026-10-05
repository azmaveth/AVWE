defmodule Avwe.AutopilotTest do
  @moduledoc """
  The brain and its system on the Ember Reach, stepped as a pure region:
  Mira's routine and its plans, the jitter, the invited fire, warmth at
  night, rest, control and determinism. Sessions and the idle rule are in
  `test/e2e/autopilot_test.exs`.
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

  defp day_number(region), do: Integer.floor_div(region.time, @day)

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

      # Every plan ran to its end, step by step.
      assert routine_steps(events) ==
               [{0, 0}, {0, 1}, {0, 2}, {1, 0}, {1, 1}, {1, 2}, {2, 0}, {2, 1}, {2, 2}, {3, 0}]

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

      assert Enum.all?(decided(events), &String.starts_with?(&1.intent_ref, "auto-mira-vale-"))

      # Still on the last entry's plan at 04:00: resting until dawn.
      assert %{why: :routine, current: 0.6, plan: %{entry: 3, steps: [], ref: "auto-" <> _}} =
               record(final)
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
      decided = events |> decided() |> Enum.map(& &1.intent_ref)

      assert results(events) |> Enum.map(& &1.ref) |> Enum.sort() ==
               Enum.sort(decided -- (pending ++ running))

      assert Enum.all?(Region.pending(final), &(&1.controller == :autopilot))
    end
  end

  describe "plans" do
    @bend [{:go, target: "the-dry-bend"}]

    test "two entries ten minutes apart in one long step: the last is taken, both are done" do
      region =
        Ember.region()
        |> Region.put_component(@mira, :routine, [
          %{at: 4 * 3600 + 30 * 60, do: @bend, note: "first"},
          %{at: 4 * 3600 + 40 * 60, do: [{:go, target: "ashwarden-lodge"}], note: "last"}
        ])

      {[{after_step, events}], _final} = run(region, 1, 3600)
      day = day_number(after_step)

      assert [%{why: :routine, entry: 1, note: "last"}] = decided(events)
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

    test "a plan is dropped when control is taken, and does not resume on release" do
      {trace, walking} = Ember.region() |> run(35)
      assert %{verb: :go, target: "the-dry-bend", ref: ref} = action(walking)
      assert %{plan: %{entry: 0, steps: [_wait, _home], ref: ^ref}} = record(walking)

      {[{held, _events}], _final} = walking |> Ember.controlled(@mira, :human) |> run(1)
      assert %{plan: nil} = record(held)

      # Her own again, she carries the journey on but not the plan: no wait
      # at the bend, and the cold dark takes her home.
      {trace2, _final} = held |> released() |> run(60)
      events = events(trace ++ trace2)
      assert [_bend] = arrivals(events, "the-dry-bend")
      assert routine_steps(events) == [{0, 0}]
      assert [%{why: :rest, utility: 0.55} | _rest] = decided(events(trace2))
      assert [_home] = arrivals(events, "ember-reach")
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
    test "by a lit hearth on a cold night she stays by the fire" do
      # 21:00 on a cold 813 night, Mira at the lodge, whose hearth a player
      # has just lit for her. Over three hours she neither sets off home nor
      # turns back for the warmth: she keeps her place, and at 22:00 rests
      # there by the fire.
      region =
        {813, day: 220, hour: 21}
        |> Ember.region()
        |> Region.put_component(@mira, :position, Ember.places().lodge)
        |> kindled(@lodge_hearth)

      assert Region.get(region, @lodge_hearth, :hearth).burning
      assert region.env.air_c < Autopilot.cold_c()

      {trace, final} = run(region, 3 * 60)
      events = events(trace)

      assert length(departures(events)) <= 1
      assert at_place?(final, "ashwarden-lodge")

      {stays, [rest | later]} = events |> decided() |> Enum.split_while(&(&1.why == :stay))
      assert stays != []
      assert Enum.all?(stays, &(&1.utility == 0.6))
      assert %{why: :routine, entry: 3, step: 0} = rest
      assert Enum.all?(later, &(&1.why == :stay))

      waits = for %{ref: "auto-" <> _step} = result <- results(events), do: result
      assert Enum.all?(waits, &(&1.verb == :wait and &1.params == %{for: 1800}))
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
      assert Enum.all?(results(events), &(&1.verb == :wait and &1.params == %{for: 600}))

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
      assert [%{why: _why}] = decided(events)
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
