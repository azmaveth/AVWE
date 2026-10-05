defmodule Avwe.Systems.Daylight do
  @moduledoc """
  Sunlight, as a region-wide `:light` value from 0.0 (night) to 1.0 (noon).

  The sun rises at 06:00 and sets at 19:00 every day, as in late summer in the
  Ember Reach. Seasons come later. Emits `:sunrise` and `:sunset` events stamped
  with the exact moment, at most one of each per step.
  """

  @behaviour Avwe.System

  alias Avwe.{Calendar, Event, Region, Tick}

  @sunrise 6 * 3_600
  @sunset 19 * 3_600

  @impl Avwe.System
  def run(region, tick) do
    light = tick |> Tick.end_time() |> Calendar.time_of_day() |> light()
    {Region.put_env(region, :light, light), events(tick)}
  end

  @doc "Sunlight for a time of day given in seconds since midnight."
  @spec light(non_neg_integer()) :: float()
  def light(seconds) when seconds <= @sunrise or seconds >= @sunset, do: 0.0
  def light(seconds), do: :math.sin(:math.pi() * (seconds - @sunrise) / (@sunset - @sunrise))

  defp events(tick) do
    for {type, at} <- [sunrise: @sunrise, sunset: @sunset],
        Tick.crossed?(tick, Calendar.day(), at) do
      Event.new(type, time: Tick.last_occurrence(tick, Calendar.day(), at))
    end
  end
end
