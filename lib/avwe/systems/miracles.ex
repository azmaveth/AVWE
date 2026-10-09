defmodule Avwe.Systems.Miracles do
  @moduledoc """
  Applies miracle events when their time comes.

  A miracle event is an entity with a `:miracle` component:

      %{kind: :event, at: time, target: "lamp-1", component: :lamp,
        set: %{power_w: 0.0}, cause: :unknown, note: "...", applied_at: nil}

  When its time comes, `set` is merged into the target's component, along with
  `miracle: id` and `changed_at: at`, so the change is annotated where it
  happened. The `:miracle` event this emits is for the game master: whoever
  lives in the world perceives only the effects, through the systems that
  respond to the change.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Tick}

  @impl Avwe.System
  def system_id, do: "sim/miracles"

  @impl Avwe.System
  def prepare(region) do
    {region, _events} = apply_due(region, region.time)
    region
  end

  @impl Avwe.System
  def run(region, tick), do: apply_due(region, Tick.end_time(tick))

  defp apply_due(region, now) do
    region
    |> Region.with_components([:miracle])
    |> Enum.map(&{&1, Region.get(region, &1, :miracle)})
    |> Enum.filter(fn {_id, miracle} ->
      miracle.kind == :event and miracle.applied_at == nil and miracle.at <= now
    end)
    |> Enum.sort_by(fn {id, miracle} -> {miracle.at, id} end)
    |> Enum.reduce({region, []}, fn {id, miracle}, {acc, events} ->
      {apply_miracle(acc, id, miracle), events ++ [announce(id, miracle)]}
    end)
  end

  defp apply_miracle(region, id, miracle) do
    current = Region.get(region, miracle.target, miracle.component) || %{}

    changed =
      current |> Map.merge(miracle.set) |> Map.merge(%{miracle: id, changed_at: miracle.at})

    region
    |> Region.put_component(miracle.target, miracle.component, changed)
    |> Region.put_component(id, :miracle, %{miracle | applied_at: miracle.at})
  end

  defp announce(id, miracle) do
    Event.new(:miracle,
      entity: id,
      time: miracle.at,
      data: Map.take(miracle, [:target, :component, :set, :cause, :note])
    )
  end
end
