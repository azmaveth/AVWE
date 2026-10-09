defmodule Avwe.Rules.Earthlike.Fire do
  @moduledoc "Hearths: wood burning, the heat and the smoke it gives, and fires that do not go out."

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.fire"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:component, :hearth}]

  @impl Avwe.Rule
  def provides, do: [:fire_sources]

  # After the scheduled changes (a hearth's fuel is one) and the river it is
  # lit beside; before the heat that takes what it burns, and the bodies.
  @impl Avwe.Rule
  def systems do
    [
      {"step", Avwe.Systems.Fire,
       runs_after: ["sim/miracles", "earthlike.river/step"], runs_before: ["play/movement"]}
    ]
  end
end
