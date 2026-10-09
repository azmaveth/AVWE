defmodule Avwe.Rules.Earthlike.Weather do
  @moduledoc """
  The air: its temperature through the day and the year, the temperature of the
  sky, and the wind a world's climate sets (which no system changes).
  """

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.weather"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:env, :air_c}, {:env, :sky_c}, {:env, :wind}]

  @impl Avwe.Rule
  def provides, do: [:air_temperature, :sky_temperature, :wind]

  @impl Avwe.Rule
  def systems do
    [{"step", Avwe.Systems.Weather, runs_after: ["sim/miracles"]}]
  end
end
