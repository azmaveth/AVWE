defmodule Avwe.RulePackage do
  @moduledoc """
  A set of rules shipped together, with the presets that name some of them
  (`docs/engine-spec.md`, 4.1). The engine's own `sim` and `play` are one
  package (`Avwe.Rules.Engine`) and the Earth-like physics another
  (`Avwe.Rules.Earthlike`); a world that runs other physics lists the rules of
  another package. `Avwe.Ruleset` finds the packages in `config :avwe,
  :rule_packages`.
  """

  @doc "The rule modules the package ships (each implements `Avwe.Rule`)."
  @callback rules() :: [module()]

  @doc """
  Named sets of rule ids: a preset `earthlike` is a list of them, `play`,
  `earthlike.fire` and so on.
  """
  @callback presets() :: %{String.t() => [String.t()]}
end
