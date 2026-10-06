defmodule Avwe.Systems.Memory do
  @moduledoc """
  What a body perceives is remembered in the world, so whoever takes it next
  can be told what happened while nobody held it ("While you were away",
  `Avwe.Perception.away/2`).

  Runs last, after every system that emits events. Each step, for every body
  with a position, it runs `Avwe.Perception.percepts/3` over this step's
  events (`Avwe.Region.step_events/2`) against the step's view with terrain,
  and keeps the percepts worth remembering: the sensed ones but sunrise and
  sunset, and the results that say something (a summary), except a
  notebook's reading, which is not a memory of itself. Its own progress
  reports are not kept either. Each entry is `%{time, type, summary}`; the
  body's `memory: %{entries: [...]}` keeps the newest 50, newest first.

  This is state, and replay regenerates it, since perception is pure. It
  also means a change to prose changes what new memories say; old entries
  keep their words.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Percept, Perception, Region}

  @keep 50
  @forgettable [:sunrise, :sunset]

  @doc "How many entries a body's memory keeps."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @impl Avwe.System
  def run(region, tick) do
    case region |> Region.step_events(tick) |> Enum.reject(&reading?/1) do
      [] ->
        {region, []}

      events ->
        view = region |> Region.view() |> Map.put(:terrain, region.terrain)

        remembered =
          region
          |> Region.with_components([:body, :position])
          |> Enum.reduce(region, &remember(&2, &1, view, events))

        {remembered, []}
    end
  end

  defp remember(region, body, view, events) do
    case view |> Perception.percepts(body, events) |> Enum.filter(&memorable?/1) do
      [] ->
        region

      percepts ->
        old = Map.get(Region.get(region, body, :memory) || %{}, :entries, [])
        new = Enum.map(percepts, &%{time: &1.time, type: &1.type, summary: &1.summary})
        entries = Enum.take(Enum.reverse(new, old), @keep)
        Region.put_component(region, body, :memory, %{entries: entries})
    end
  end

  defp reading?(%Event{type: :action_result, data: %{verb: :read}}), do: true
  defp reading?(_event), do: false

  defp memorable?(%Percept{summary: summary}) when not is_binary(summary), do: false
  defp memorable?(%Percept{kind: :sensed, type: type}), do: type not in @forgettable
  defp memorable?(%Percept{kind: :result}), do: true
  defp memorable?(_progress), do: false
end
