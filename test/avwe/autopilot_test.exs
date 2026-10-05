defmodule Avwe.AutopilotTest do
  @moduledoc """
  The brain and its system on the Ember Reach, stepped as a pure region:
  Mira's routine, the jitter, the invited fire, rest, control and
  determinism. Sessions and the idle rule are in `test/e2e/autopilot_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Avwe.{Autopilot, Calendar, Event, Quire, Region, Worldgen}
  alias Avwe.Test.{Ember, Fixtures}

  @mira "mira-vale"
  @hearth "town-hearth"
  @day Calendar.day()

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

  # The region in `trace` whose time is `{hour, minute}` of its day.
  defp at(trace, hour, minute) do
    Enum.find_value(trace, fn {region, _events} ->
      %{hour: h, minute: m} = Calendar.describe(region.time)
      if {h, m} == {hour, minute}, do: region
    end)
  end

  defp position(region, body \\ @mira), do: Region.get(region, body, :position)
  defp action(region, body \\ @mira), do: Region.get(region, body, :action)

  defp at_place?(region, place, body \\ @mira),
    do: Avwe.Space.distance(position(region, body), Region.get(region, place, :position)) <= 2

  defp departures(events, body \\ @mira) do
    for %Event{type: :departed, entity: ^body, time: time} <- events,
        do: Calendar.describe(time)
  end

  defp day_number(region), do: Integer.floor_div(region.time, @day)

  describe "Mira's routine" do
    setup do
      {trace, _final} = Ember.region({813, day: 220, hour: 4}) |> run(1440)
      %{trace: trace, events: events(trace)}
    end

    test "walks the banks before dawn, warms her hands at the lodge, rests at home", %{
      trace: trace
    } do
      # Left by 04:40 (the step after 04:30, plus up to five minutes of
      # jitter) and at the bend by 05:00. It is dark and cold there, so she
      # walks the banks back home, where the survey starts at 06:30.
      left = at(trace, 4, 40)
      assert position(left) != Ember.places().town or match?(%{verb: :go}, action(left))

      [%Event{time: arrived}] =
        for %Event{type: :arrived, data: %{place: "the-dry-bend"}} = event <- events(trace),
            do: event

      assert arrived <= Calendar.at(813, day: 220, hour: 5)

      # At the lodge from 18:10 until sunset, when rest takes her home.
      for {region, _events} <- trace,
          %{hour: hour, minute: minute} = Calendar.describe(region.time),
          {hour, minute} >= {18, 10} and {hour, minute} <= {19, 0} do
        assert at_place?(region, "ashwarden-lodge"), "not at the lodge at #{hour}:#{minute}"
      end

      resting = at(trace, 22, 10)
      assert at_place?(resting, "ember-reach")
      assert %{verb: :wait, params: %{until: :dawn}} = action(resting)
    end

    test "fires each entry once a day, naming it", %{trace: trace, events: events} do
      {final, _events} = List.last(trace)
      day = day_number(at(trace, 12, 0))

      assert Region.get(final, @mira, :autopilot).done == Map.new(0..5, &{&1, day})

      routine = for %{why: :routine} = data <- decided(events), do: data
      assert Enum.map(routine, & &1.entry) == Enum.to_list(0..5)

      assert Enum.map(routine, & &1.note) == [
               "walks the banks before dawn",
               "the survey",
               nil,
               "warms her hands at the lodge",
               nil,
               nil
             ]

      assert Enum.all?(decided(events), &String.starts_with?(&1.intent_ref, "auto-mira-vale-"))
      assert %{why: :routine, current: 0.6} = Region.get(final, @mira, :autopilot)
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
  end

  describe "the invited fire" do
    # The air is at its coldest before dawn (it never falls below 13 °C in
    # this weather, and is "cool" below 15 °C from about 20:20 to 06:57), so
    # the cold night is 03:00. The river bed beside the town is 29 °C in
    # 812 and 17 °C in 813 at that hour.
    test "in 812 Mira lights her hearth within ten minutes of a cold night" do
      region = Ember.region({812, day: 199, hour: 3})
      assert region.env.air_c < Autopilot.cold_c()
      assert Autopilot.invited?(region, @hearth)

      {trace, final} = run(region, 10)
      assert [%Event{entity: @hearth, data: %{by: @mira}}] = trace |> events() |> of(:fire_lit)
      assert [%{why: :warmth, utility: 0.8} | _rest] = trace |> events() |> decided()
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

      released = Region.put_component(final, @mira, :control, %{holder: nil, since: final.time})
      {[{_region, events}], _final} = run(released, 1)
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

      arrived =
        for %Event{type: :arrived, entity: @mira, data: %{place: place}} <- events, do: place

      assert "the-dry-bend" in arrived
      assert "ashwarden-lodge" in arrived
      assert "ember-reach" in arrived
      assert Enum.any?(results(events), &(&1.verb == :follow and &1.reason == :end_of_channel))

      assert events |> decided() |> Enum.filter(&(&1.why == :routine)) |> Enum.map(& &1.entry) ==
               Enum.to_list(0..5)
    end
  end

  defp of(events, type), do: Enum.filter(events, &(&1.type == type))
end
