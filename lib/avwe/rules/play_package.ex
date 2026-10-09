defmodule Avwe.Rules.PlayPackage do
  @moduledoc """
  The package of the agent layer's rule: `play`, which every world with bodies
  lists (`docs/engine-spec.md`, 4.2). (`sim`, which every world runs, is the
  kernel's own and needs no package.)
  """

  @behaviour Avwe.RulePackage

  @impl Avwe.RulePackage
  def rules, do: [Avwe.Rules.Play]

  @impl Avwe.RulePackage
  def presets, do: %{}
end
