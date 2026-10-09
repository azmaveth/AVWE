defmodule Avwe.Rules.Earthlike.Heat do
  @moduledoc """
  Heat in the ground and the air: the sun and the sky warm and cool it, the
  hearths and the river's water give theirs to it.
  """

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.heat"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:field, :heat}]

  @impl Avwe.Rule
  def provides, do: [:ground_heat]

  @impl Avwe.Rule
  def requires, do: [:air_temperature, :light, :sky_temperature]

  @impl Avwe.Rule
  def uses, do: [:fire_sources, :river_water, :terrain]

  # After the fire has burned, before the bodies move through the warmth.
  @impl Avwe.Rule
  def systems do
    [
      {"step", Avwe.Systems.Heat,
       runs_after: ["earthlike.fire/step"], runs_before: ["play/movement"]}
    ]
  end
end
