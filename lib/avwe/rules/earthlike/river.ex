defmodule Avwe.Rules.Earthlike.River do
  @moduledoc "The river: water running down the channel from a spring, reach by reach."

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.river"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:component, :river}, {:component, :spring}]

  @impl Avwe.Rule
  def provides, do: [:river_water]

  @impl Avwe.Rule
  def requires, do: [:air_temperature]

  @impl Avwe.Rule
  def uses, do: [:terrain]

  @impl Avwe.Rule
  def systems do
    [{"step", Avwe.Systems.River, runs_after: ["earthlike.weather/step"]}]
  end
end
