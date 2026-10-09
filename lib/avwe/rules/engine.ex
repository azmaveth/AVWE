defmodule Avwe.Rules.Engine do
  @moduledoc """
  The package of the engines' own rules: `sim`, which every world runs, and
  `play`, which every world with bodies lists (`docs/engine-spec.md`, 4.2).
  """

  @behaviour Avwe.RulePackage

  @impl Avwe.RulePackage
  def rules, do: [Avwe.Rules.Sim, Avwe.Rules.Play]

  @impl Avwe.RulePackage
  def presets, do: %{}
end
