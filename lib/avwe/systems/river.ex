defmodule Avwe.Systems.River do
  @moduledoc """
  The river, simulated reach by reach from its source to where it leaves the
  map.

  The river is an entity (`"river"`) whose `:river` component holds the state
  of each reach (`Avwe.Terrain.reaches/1`): its volume of water, the water's
  temperature, and whether it has fallen silent. Water comes from the spring
  at its source (the `:spring` component on the source's place).

  ## The model

  Each reach is a linear reservoir: water leaves it at `volume / τ`, where τ is
  the time water takes to cross it at 0.6 m/s, and a little is lost to seepage
  and evaporation (1 µm/s over a 12 m wide bed). A step of any length uses the
  exact solution for constant inflow, so history mode's hour-long steps stay
  stable. Each reach's outflow is the next reach's inflow.

  ## Sub-steps

  Each reach is solved exactly, but the chain feeds the next reach the step's
  *mean* outflow, so a step longer than a reach's transit (about 170 s) can
  move the drain front only one reach per step: at hour steps the river would
  take a day to run dry instead of two hours, with the water that should have
  left the map booked as lost and the silences stamped hours late. So a step
  is cut into sub-steps of at most `@substep_s` (60 s, the live step) inside
  `run/2` and the settle alike, each sub-step taking the exact mean air of
  its own interval and stamping its events with its own end time. An hour
  step then reproduces sixty minute steps exactly; at 300 s sub-steps (nearly
  two transits) the front still lagged by 5 % of the water. Twenty-three
  reaches by sixty sub-steps is a quarter of a millisecond an hour, 6 ms a
  day.

  Water mixes with what flows in and cools toward the air, taking the exact
  mean air over each sub-step from `Avwe.Systems.Weather`. The water's heat
  stays outside the ground's budget: a reach is a boundary reservoir, like
  the air, and the ground books what it takes from it (`Avwe.Systems.Heat`).
  The six hour cooling constant already includes what the banks take.
  One-way, and declared.

  When the spring stops, upstream reaches drain first and the silence moves
  downstream, so the Dry Bend goes quiet before the town.

  ## Events

    * `:river_silent` / `:river_flowing` when a reach's depth crosses 5 cm,
      positioned at the middle of the reach and stamped with the end of the
      sub-step it happened in.
    * `:spring_stopped` / `:spring_started` when the spring's flow stops or
      starts, positioned at the source.

  ## Conservation

  `last_step` on the river records the water that came in, went out of the
  map and was lost in the last step, in m³. Storage only ever changes by
  inflow minus outflow minus loss, and loss never exceeds the seepage rate.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Terrain}
  alias Avwe.Systems.Weather

  @river "river"
  @width_m 12.0
  @speed_m_per_s 0.6
  @loss_m_per_s 1.0e-6
  @silent_depth_m 0.05
  @cooling_s 6 * 3_600
  @substep_s 60
  @settle_step_s 3_600
  @settle_limit_s 2 * 86_400
  @zero_step %{inflow_m3: 0.0, outflow_m3: 0.0, lost_m3: 0.0}

  @doc "The river entity's id."
  @spec id() :: String.t()
  def id, do: @river

  @doc "Water depth below which a reach counts as silent, in metres."
  @spec silent_depth_m() :: float()
  def silent_depth_m, do: @silent_depth_m

  @doc "A reach's depth in metres."
  @spec depth_m(map(), map()) :: float()
  def depth_m(reach_state, reach), do: reach_state.volume / (@width_m * reach.length_m)

  @impl Avwe.System
  def system_id, do: "earthlike.river/step"

  @impl Avwe.System
  def prepare(%Region{terrain: %Terrain{} = terrain} = region) do
    case Region.get(region, @river, :river) do
      nil -> region
      river -> Region.put_component(region, @river, :river, settle(region, river, terrain))
    end
  end

  def prepare(region), do: region

  @impl Avwe.System
  def run(%Region{terrain: %Terrain{} = terrain} = region, tick) do
    case Region.get(region, @river, :river) do
      nil ->
        {region, []}

      river ->
        spring = Region.get(region, river.source, :spring)

        {river, events} =
          flow(river, terrain, spring.flow_m3_s, spring.temp_c, tick.time, tick.dt)

        spring_events = spring_events(river.inflow, spring.flow_m3_s, river.source, terrain)

        {Region.put_component(region, @river, :river, %{river | inflow: spring.flow_m3_s}),
         spring_events ++ events}
    end
  end

  def run(region, _tick), do: {region, []}

  @doc """
  The reaches of a river flowing steadily at `flow_m3_s` from a spring at
  `temp_c`, under a constant air of `air_c`: each reach full to its steady
  volume, the water cooling toward the air as it goes down.
  """
  @spec steady_reaches(Terrain.t(), float(), float(), float()) :: tuple()
  def steady_reaches(%Terrain{} = terrain, flow_m3_s, temp_c, air_c) do
    {states, _carry} =
      terrain
      |> Terrain.reaches()
      |> Enum.map_reduce({flow_m3_s, temp_c}, fn reach, {q, t} ->
        tau = reach.length_m / @speed_m_per_s
        out = max(q - loss_rate(reach), 0.0)
        volume = out * tau
        temp_out = equilibrium_c(mixing_rate(q, volume), t, air_c)
        state = %{volume: volume, temp_c: temp_out}
        {Map.put(state, :silent, depth_m(state, reach) < @silent_depth_m), {out, temp_out}}
      end)

    List.to_tuple(states)
  end

  # The river at the region's starting time: flowing steadily at the spring's
  # natural rate under the daily mean air, then, if the spring has since
  # stopped, draining for as long as it has been stopped (up to two days,
  # after which it is dry whatever the air did), under the air of each hour.
  defp settle(region, river, terrain) do
    spring = Region.get(region, river.source, :spring)

    steady =
      steady_reaches(terrain, spring.natural_m3_s, spring.temp_c, Weather.daily_mean_air_c())

    river = %{river | reaches: steady, inflow: spring.natural_m3_s}

    case spring do
      %{flow_m3_s: flow} when flow > 0 ->
        river

      %{changed_at: changed_at} ->
        drained = min(region.time - changed_at, @settle_limit_s)
        steps = div(drained, @settle_step_s)
        from = region.time - drained

        river
        |> drain(terrain, spring.temp_c, from, steps, @settle_step_s)
        |> drain(
          terrain,
          spring.temp_c,
          from + steps * @settle_step_s,
          1,
          rem(drained, @settle_step_s)
        )
        |> Map.put(:inflow, 0.0)
    end
  end

  defp drain(river, _terrain, _temp, _from, _steps, 0), do: river

  defp drain(river, terrain, temp, from, steps, dt) do
    Enum.reduce(0..(steps - 1)//1, river, fn i, acc ->
      {acc, _events} = flow(acc, terrain, 0.0, temp, from + i * dt, dt)
      acc
    end)
  end

  # One step of `dt` from `t0`, as sub-steps of at most `@substep_s` each
  # under the mean air of its own interval. `last_step` sums the sub-steps;
  # the events carry the end of the sub-step they happened in.
  defp flow(river, terrain, inflow, inflow_temp, t0, dt) do
    reaches = Terrain.reaches(terrain)

    {river, last_step, events} =
      Enum.reduce(substeps(t0, dt), {river, @zero_step, []}, fn {s0, s1}, {acc, totals, events} ->
        air_c = Weather.mean_air_c(s0, s1)
        {acc, step, new_events} = flow_once(acc, reaches, inflow, inflow_temp, air_c, s1, s1 - s0)
        {acc, Map.merge(totals, step, fn _key, a, b -> a + b end), events ++ new_events}
      end)

    {%{river | last_step: last_step}, events}
  end

  # The sub-steps of a step: `n` intervals of near-equal integer length that
  # cover `[t0, t0 + dt]`, each at most `@substep_s` long.
  defp substeps(t0, dt) do
    n = div(dt + @substep_s - 1, @substep_s)
    for i <- 0..(n - 1)//1, do: {t0 + div(i * dt, n), t0 + div((i + 1) * dt, n)}
  end

  defp flow_once(river, reaches, inflow, inflow_temp, air_c, time, dt) do
    {states, {outflow, _temp, lost, events}} =
      river.reaches
      |> Tuple.to_list()
      |> Enum.zip(Enum.with_index(reaches))
      |> Enum.map_reduce({inflow, inflow_temp, 0.0, []}, fn {state, {reach, k}},
                                                            {q, t, lost, events} ->
        {state, out, temp_out, reach_lost} = reach_step(state, reach, q, t, air_c, dt)

        events =
          if state.silent != reach_silent?(river, k),
            do: [silence_event(state, reach, k, time) | events],
            else: events

        {state, {out, temp_out, lost + reach_lost, events}}
      end)

    step = %{inflow_m3: inflow * dt, outflow_m3: outflow * dt, lost_m3: lost}
    {%{river | reaches: List.to_tuple(states)}, step, Enum.reverse(events)}
  end

  # One reach for one step: the exact solution of dV/dt = I - L - V/τ for
  # constant inflow I and loss L, clamped at empty, and of the well-mixed
  # water's temperature, dT/dt = (I/V)(T_in - T) - (T - T_air)/τ_c, with V
  # taken as the step's mean volume. The next reach receives the step's mean
  # outflow temperature, so sixty minute steps and one hour step agree.
  defp reach_step(state, reach, inflow, inflow_temp, air_c, dt) do
    tau = reach.length_m / @speed_m_per_s
    loss = if state.volume > 0 or inflow > 0, do: loss_rate(reach), else: 0.0
    net = inflow - loss

    volume = max(net * tau + (state.volume - net * tau) * :math.exp(-dt / tau), 0.0)
    out = max((state.volume + net * dt - volume) / dt, 0.0)
    lost = state.volume + inflow * dt - out * dt - volume

    mixing = mixing_rate(inflow, (state.volume + volume) / 2)
    equilibrium = equilibrium_c(mixing, inflow_temp, air_c)
    x = (mixing + 1 / @cooling_s) * dt
    temp = equilibrium + (state.temp_c - equilibrium) * :math.exp(-x)
    temp_out = equilibrium + (state.temp_c - equilibrium) * mean_factor(x)

    state = %{
      volume: volume,
      temp_c: temp,
      silent: volume / (@width_m * reach.length_m) < @silent_depth_m
    }

    {state, out, temp_out, lost}
  end

  # The rate at which inflow replaces a reach's water, per second.
  defp mixing_rate(inflow, volume) when volume > 0, do: inflow / volume
  defp mixing_rate(_inflow, _volume), do: 0.0

  # The temperature water settles at under a mixing rate, an inflow
  # temperature and an air temperature.
  defp equilibrium_c(mixing, inflow_temp, air_c) do
    (mixing * inflow_temp + air_c / @cooling_s) / (mixing + 1 / @cooling_s)
  end

  # (1 - e^-x) / x: the mean of e^-t over the step, relative to its start.
  defp mean_factor(x) when x < 1.0e-5, do: 1 - x / 2 + x * x / 6
  defp mean_factor(x), do: (1 - :math.exp(-x)) / x

  defp loss_rate(reach), do: @loss_m_per_s * @width_m * reach.length_m

  defp reach_silent?(river, k), do: elem(river.reaches, k).silent

  defp silence_event(state, reach, k, time) do
    type = if state.silent, do: :river_silent, else: :river_flowing
    Event.new(type, entity: @river, time: time, data: %{reach: k, position: reach.mid})
  end

  defp spring_events(before, now, source, terrain) do
    position = Terrain.source(terrain)

    cond do
      before > 0 and now <= 0 ->
        [Event.new(:spring_stopped, entity: source, data: %{position: position})]

      before <= 0 and now > 0 ->
        [Event.new(:spring_started, entity: source, data: %{position: position})]

      true ->
        []
    end
  end
end
