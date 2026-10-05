defmodule Avwe.Systems.Weather do
  @moduledoc """
  The air and the sky: the temperatures the ground and the river exchange
  heat with, and the wind the smoke drifts on.

  Late summer in the Ember Reach, every day alike: the air warms from 13 °C at
  06:00 to 25 °C at 15:00 along a quarter sine, then cools along an
  exponential with a three-hour time constant back to 13 °C at dawn. The sky
  (what the ground radiates to) is always 10 °C below the air. The curve is
  piecewise so that the evening air falls fast enough for the banks to steam at
  dusk, which a cosine never gives; it is continuous at both joins and has a
  closed-form integral, so a step of any length can take the exact mean air
  over its interval rather than a sample.

  The wind is constant per region, set from the world's climate config
  (`env.wind`). Nothing here is random, so the systems that read it never
  touch `Avwe.Tick.rng/2`.

  Publishes `env.air_c` and `env.sky_c`, the instantaneous values at the end
  of the step, for perception. Emits no events.
  """

  @behaviour Avwe.System

  alias Avwe.{Calendar, Region, Tick}

  @day 24 * 3_600
  @t_min 13.0
  @t_max 25.0
  @t_rise 6 * 3_600
  @t_peak 15 * 3_600
  @tau_night 3 * 3_600
  @sky_drop 10.0

  @delta_t @t_max - @t_min
  @rise_s @t_peak - @t_rise
  @night_s @day - @rise_s
  @e_night :math.exp(-@night_s / @tau_night)

  @type time :: Calendar.time()

  @impl Avwe.System
  def prepare(region), do: put_air(region, region.time)

  @impl Avwe.System
  def run(region, tick), do: {put_air(region, Tick.end_time(tick)), []}

  @doc "The air temperature at a world time, in °C."
  @spec air_c(time()) :: float()
  def air_c(time) do
    tod = Calendar.time_of_day(time)

    if tod >= @t_rise and tod < @t_peak do
      @t_min + @delta_t * :math.sin(:math.pi() / 2 * (tod - @t_rise) / @rise_s)
    else
      s = Integer.mod(tod - @t_peak, @day)
      @t_min + @delta_t * (:math.exp(-s / @tau_night) - @e_night) / (1 - @e_night)
    end
  end

  @doc "The sky temperature at a world time, in °C: the air less #{@sky_drop}."
  @spec sky_c(time()) :: float()
  def sky_c(time), do: air_c(time) - @sky_drop

  @doc """
  The exact mean air temperature over `t0 < t1`, from the closed-form integral
  of the daily curve.
  """
  @spec mean_air_c(time(), time()) :: float()
  def mean_air_c(t0, t1) when t1 > t0 do
    days = Integer.floor_div(t1, @day) - Integer.floor_div(t0, @day)

    (days * day_integral() + integral(Integer.mod(t1, @day)) - integral(Integer.mod(t0, @day))) /
      (t1 - t0)
  end

  @doc "The exact mean sky temperature over `t0 < t1`."
  @spec mean_sky_c(time(), time()) :: float()
  def mean_sky_c(t0, t1), do: mean_air_c(t0, t1) - @sky_drop

  @doc "The mean air temperature over a whole day."
  @spec daily_mean_air_c() :: float()
  def daily_mean_air_c, do: day_integral() / @day

  @doc "The sky's drop below the air, in K."
  @spec sky_drop() :: float()
  def sky_drop, do: @sky_drop

  defp put_air(region, time) do
    air = air_c(time)

    region
    |> Region.put_env(:air_c, air)
    |> Region.put_env(:sky_c, air - @sky_drop)
  end

  # The integral of air_c from midnight to a time of day. Midnight falls in
  # the night segment, 9 h after the 15:00 peak.
  defp integral(tod) when tod < @t_rise,
    do: night(@night_s - @t_rise + tod) - night(@night_s - @t_rise)

  defp integral(tod) when tod < @t_peak, do: rise_integral() + day(tod - @t_rise)
  defp integral(tod), do: peak_integral() + night(tod - @t_peak)

  defp rise_integral, do: night(@night_s) - night(@night_s - @t_rise)
  defp peak_integral, do: rise_integral() + day(@rise_s)
  defp day_integral, do: peak_integral() + night(@night_s - @t_rise)

  # Integral of the rising quarter sine over its first u seconds.
  defp day(u) do
    @t_min * u +
      @delta_t * (2 * @rise_s / :math.pi()) * (1 - :math.cos(:math.pi() * u / (2 * @rise_s)))
  end

  # Integral of the night exponential over its first s seconds.
  defp night(s) do
    @t_min * s +
      @delta_t * (@tau_night * (1 - :math.exp(-s / @tau_night)) - s * @e_night) / (1 - @e_night)
  end
end
