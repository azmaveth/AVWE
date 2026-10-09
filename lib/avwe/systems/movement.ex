defmodule Avwe.Systems.Movement do
  @moduledoc """
  Walks bodies along their journey's path: to a place (`:go`), along the
  river channel (`:follow`) or in a compass direction (`:walk`).

  Bodies walk at 1.3 m/s; terrain doesn't slow them yet. Emits an
  `:action_progress` event at each quarter of the way, then the action's
  result on arrival. Arriving at a place (`:go`) also emits `:arrived`, which
  others nearby can see.
  """

  @behaviour Avwe.System

  alias Avwe.{Actions, Event, Region, Space}

  @walking_speed_m_per_s 1.3
  @quarters [0.25, 0.5, 0.75]
  @finished %{go: :arrived, follow: :end_of_channel, walk: :walked}

  @impl Avwe.System
  def system_id, do: "play.movement/step"

  @impl Avwe.System
  def run(region, tick) do
    region
    |> Region.with_components([:action, :position])
    |> Enum.filter(&match?(%{path: _path}, Region.get(region, &1, :action)))
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
        |> Region.put_component(body, :position, Space.along(action.path, covered))
        |> Region.put_component(body, :action, %{action | covered: covered})

      {region, events ++ progress(body, action, covered)}
    end
  end

  defp arrive(region, events, body, action) do
    destination = List.last(action.path)

    {region, done} =
      region
      |> Region.put_component(body, :position, destination)
      |> Actions.complete(body, :success, @finished[action.verb])

    {region, events ++ done ++ arrived(body, action, destination)}
  end

  defp arrived(body, %{verb: :go, target: place}, destination),
    do: [Event.new(:arrived, entity: body, data: %{place: place, position: destination})]

  defp arrived(_body, _action, _destination), do: []

  defp progress(body, action, covered) do
    before = action.covered / action.distance
    now = covered / action.distance

    for quarter <- @quarters, before < quarter and now >= quarter do
      Event.new(:action_progress,
        entity: body,
        data: action |> Map.take([:ref, :verb, :target, :params]) |> Map.put(:progress, quarter)
      )
    end
  end
end
