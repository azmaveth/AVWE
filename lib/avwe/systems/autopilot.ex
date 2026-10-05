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
  cancelling of what it is doing. When control is released, autopilot
  resumes at the next step.

  Each choice is recorded in the body's `:autopilot` component
  (`%{current: utility, why: atom, since: time, done: %{entry => day}}`) and
  announced with a `:decided` event (`entity: body, data: %{why, intent_ref,
  utility}`, plus `entry` and `note` for a routine entry) that bodies never
  perceive: it is for the game master, like `:miracle`.
  """

  @behaviour Avwe.System

  alias Avwe.{Autopilot, Event, Intent, Region, Tick}

  @impl Avwe.System
  def run(region, tick) do
    bodies = Region.with_components(region, [:body, :autopilot, :position])
    jitter = Autopilot.jitter(tick, bodies)

    bodies
    |> Enum.filter(&free?(region, &1))
    |> Enum.reduce({region, []}, fn body, {acc, events} ->
      case Autopilot.decide(acc, tick, body, jitter[body]) do
        :stay -> {acc, events}
        {:act, choice} -> act(acc, tick, body, choice, events)
      end
    end)
  end

  defp free?(region, body) do
    case Region.get(region, body, :control) do
      %{holder: holder} -> holder == nil
      nil -> true
    end
  end

  defp act(region, tick, body, choice, events) do
    ref = "auto-#{body}-#{tick.step}"
    {verb, opts} = choice.intent
    intent = Intent.new(body, verb, [ref: ref, controller: :autopilot] ++ opts)
    record = Region.get(region, body, :autopilot)

    decided = %{
      record
      | current: choice.utility,
        why: choice.why,
        since: Tick.end_time(tick),
        done: Map.merge(record.done, Map.get(choice, :done, %{}))
    }

    data =
      choice
      |> Map.take([:entry, :note])
      |> Map.merge(%{why: choice.why, intent_ref: ref, utility: choice.utility})

    region =
      region
      |> Region.submit(intent)
      |> Region.put_component(body, :autopilot, decided)

    {region, events ++ [Event.new(:decided, entity: body, data: data)]}
  end
end
