defmodule Avwe.Rule do
  @moduledoc """
  A rule: one self-contained feature of a world (`station.power`,
  `station.atmosphere`), the unit a world's **ruleset** is made of. This is the
  rule's **model**, the half that needs nothing but the simulation: the state
  it owns, the systems that move it, and what it needs of the other rules. (Its
  embodiment, the verbs and senses by which a world's inhabitants meet it, is a second module
  that `c:facets/0` names; `docs/engine-spec.md`, 4.1.)

  A rule says what it touches, and `Avwe.Ruleset` checks the whole when a world
  loads, all problems at once, in plain words:

    * **`owns/0`**, the state keys its systems write: `{:component, name}`,
      `{:field, name}`, `{:env, name}` or `:terrain`. Two rules owning one key
      is an error: a rule that wants to affect another's state feeds it through
      entities of its own or through events, and does not write it. A rule whose
      systems may change a key it does not own, because that is what they are
      for (a scheduled change of any component), says so in `c:edits/0`.
    * **`provides/0`, `requires/0`, `uses/0`**, what it needs by capability, not
      by rule: `provides: [:power]`, `requires: [:power]`,
      `uses: [:coolant]`. An unmet `requires` is an error; an unmet `uses`
      means the rule runs without it. A capability is a state key, a pure
      query, or both.
    * **`runs_after/0`, `runs_before/0`**, what it must run after or before, by
      system id, by rule id (all its systems) or by capability (the systems of
      the rules that provide it). Everything else runs in the order of the ids.
    * **`conflicts/0`**, rules it cannot run beside.
    * **`systems/0`**, its systems, `{name, module}` or `{name, module,
      options}`; the system's id is the rule's id, a slash and the name
      (`"station.power/step"`), and the module declares the same id
      (`c:Avwe.System.system_id/0`). A rule's own systems run in the order
      listed.

  Only `id/0` and `version/0` are required. The rest have an empty default, and
  a rule declares what it has.
  """

  @typedoc "A piece of a region's state, by the name it is kept under."
  @type key :: {:component, atom()} | {:field, atom()} | {:env, atom()} | :terrain

  @type system :: {String.t(), module()} | {String.t(), module(), keyword()}

  @doc "The rule's id: `\"station.power\"`."
  @callback id() :: String.t()

  @doc "The rule's version, `\"major.minor\"`."
  @callback version() :: String.t()

  @doc "What other rules may need of this one."
  @callback provides() :: [atom()]

  @doc "What this rule cannot run without."
  @callback requires() :: [atom()]

  @doc "What this rule uses when it is there."
  @callback uses() :: [atom()]

  @doc "Rules (by id) that cannot run beside this one."
  @callback conflicts() :: [String.t()]

  @doc "The state keys this rule's systems write."
  @callback owns() :: [key()]

  @doc """
  The state keys this rule's systems may change without owning them, or `:any`.
  The one rule that has any is the engine's own, which applies scheduled changes.
  """
  @callback edits() :: :any | [key()]

  @doc "What this rule must run after, by system id, rule id or capability."
  @callback runs_after() :: [String.t() | atom()]

  @doc "What this rule must run before, by system id, rule id or capability."
  @callback runs_before() :: [String.t() | atom()]

  @doc "The rule's systems, in the order they run."
  @callback systems() :: [system()]

  @doc """
  The module that is this rule's embodiment for a layer, by the layer's name:
  `%{play: Station.Power.Play}`. Sim hands each facet to the layer that
  registered for it, and knows no more of it.
  """
  @callback facets() :: %{atom() => module()}

  @optional_callbacks provides: 0,
                      requires: 0,
                      uses: 0,
                      conflicts: 0,
                      owns: 0,
                      edits: 0,
                      runs_after: 0,
                      runs_before: 0,
                      systems: 0,
                      facets: 0

  @doc "A rule module's manifest: every callback, with the defaults for those it does not define."
  @spec manifest(module()) :: map()
  def manifest(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    %{
      module: module,
      id: module.id(),
      version: module.version(),
      provides: declared(module, :provides, []),
      requires: declared(module, :requires, []),
      uses: declared(module, :uses, []),
      conflicts: declared(module, :conflicts, []),
      owns: declared(module, :owns, []),
      edits: declared(module, :edits, []),
      runs_after: declared(module, :runs_after, []),
      runs_before: declared(module, :runs_before, []),
      systems: module |> declared(:systems, []) |> Enum.map(&system(module.id(), &1)),
      facets: declared(module, :facets, %{})
    }
  end

  defp declared(module, callback, default) do
    if function_exported?(module, callback, 0), do: apply(module, callback, []), else: default
  end

  defp system(rule_id, {name, module}), do: system(rule_id, {name, module, []})

  defp system(rule_id, {name, module, options}),
    do: %{id: rule_id <> "/" <> name, name: name, module: module, options: options}
end
