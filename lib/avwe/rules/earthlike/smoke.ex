defmodule Avwe.Rules.Earthlike.Smoke do
  @moduledoc "Smoke: puffs from burning hearths that drift on the wind, and what a nose in them smells."

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.smoke"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:field, :smoke}, {:component, :nose}]

  @impl Avwe.Rule
  def provides, do: [:smoke]

  @impl Avwe.Rule
  def requires, do: [:fire_sources, :wind]

  # After the bodies have decided (smoke is what they smell next), and before
  # memory takes down what happened in the step, smoke's events included.
  @impl Avwe.Rule
  def systems do
    [
      {"step", Avwe.Systems.Smoke, runs_after: ["play/autopilot"], runs_before: ["play/memory"]}
    ]
  end
end
