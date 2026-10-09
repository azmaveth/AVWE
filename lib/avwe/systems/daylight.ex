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
  @day 24 * 3_600
  @daylight_s @sunset - @sunrise

  @impl Avwe.System
  def system_id, do: "earthlike.daylight/step"

  @impl Avwe.System
  def prepare(region) do
    Region.put_env(region, :light, region.time |> Calendar.time_of_day() |> light())
  end

  @impl Avwe.System
  def run(region, tick) do
    light = tick |> Tick.end_time() |> Calendar.time_of_day() |> light()
    {Region.put_env(region, :light, light), events(tick)}
  end

  @doc "Sunrise, in seconds since midnight."
  @spec sunrise() :: non_neg_integer()
  def sunrise, do: @sunrise

  @doc "Sunset, in seconds since midnight."
  @spec sunset() :: non_neg_integer()
  def sunset, do: @sunset

  @doc "Sunlight for a time of day given in seconds since midnight."
  @spec light(non_neg_integer()) :: float()
  def light(seconds) when seconds <= @sunrise or seconds >= @sunset, do: 0.0
  def light(seconds), do: :math.sin(:math.pi() * (seconds - @sunrise) / (@sunset - @sunrise))

  @doc """
  The exact mean of `light/1` over the world times `t0 < t1`, from the
  closed-form integral of the half sine, so a step of any length can take the
  sun it actually received rather than a sample. About 0.345 over a day.
  """
  @spec mean_light(Calendar.time(), Calendar.time()) :: float()
  def mean_light(t0, t1) when t1 > t0 do
    days = Integer.floor_div(t1, @day) - Integer.floor_div(t0, @day)

    (days * integral(@day) + integral(Integer.mod(t1, @day)) - integral(Integer.mod(t0, @day))) /
      (t1 - t0)
  end

  # The integral of light/1 from midnight to a time of day.
  defp integral(tod) when tod <= @sunrise, do: 0.0
  defp integral(tod) when tod >= @sunset, do: 2 * @daylight_s / :math.pi()

  defp integral(tod) do
    @daylight_s / :math.pi() * (1 - :math.cos(:math.pi() * (tod - @sunrise) / @daylight_s))
  end

  defp events(tick) do
    for {type, at} <- [sunrise: @sunrise, sunset: @sunset],
        Tick.crossed?(tick, Calendar.day(), at) do
      Event.new(type, time: Tick.last_occurrence(tick, Calendar.day(), at))
    end
  end
end
