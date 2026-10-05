defmodule Avwe.Systems.Movement do
  @moduledoc """
  Walks bodies toward the place they're going.

  Bodies walk at 1.3 m/s in a straight line; terrain comes later. Emits an
  `:action_progress` event at each quarter of the way, then, on arrival, the
  action's result and an `:arrived` event that others nearby can see.
  """

  @behaviour Avwe.System

  alias Avwe.{Actions, Event, Region, Space}

  @walking_speed_m_per_s 1.3
  @quarters [0.25, 0.5, 0.75]

  @impl Avwe.System
  def run(region, tick) do
    region
    |> Region.with_components([:action, :position])
    |> Enum.filter(&match?(%{verb: :go}, Region.get(region, &1, :action)))
    |> Enum.reduce({region, []}, &walk(&1, &2, tick))
  end

  defp walk(body, {region, events}, tick) do
    action = Region.get(region, body, :action)
    step = @walking_speed_m_per_s / Space.cell_size_m() * tick.dt
    covered = min(action.covered + step, action.distance)

    if covered >= action.distance do
      arrive(region, events, body, action)
    else
      region =
        region
        |> Region.put_component(
          body,
          :position,
          Space.lerp(action.from, action.to, covered / action.distance)
        )
        |> Region.put_component(body, :action, %{action | covered: covered})

      {region, events ++ progress(body, action, covered)}
    end
  end

  defp arrive(region, events, body, action) do
    {region, done} =
      region
      |> Region.put_component(body, :position, action.to)
      |> Actions.complete(body, :success, :arrived)

    arrived =
      Event.new(:arrived, entity: body, data: %{place: action.target, position: action.to})

    {region, events ++ done ++ [arrived]}
  end

  defp progress(body, action, covered) do
    before = action.covered / action.distance
    now = covered / action.distance

    for quarter <- @quarters, before < quarter and now >= quarter do
      Event.new(:action_progress,
        entity: body,
        data: %{ref: action.ref, verb: :go, target: action.target, progress: quarter}
      )
    end
  end
end
