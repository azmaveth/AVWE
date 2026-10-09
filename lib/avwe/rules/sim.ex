defmodule Avwe.Rules.Sim do
  @moduledoc """
  The simulation engine as a rule: the part of every world that is not physics
  or bodies. It owns the places (`place`) and the scheduled changes (`miracle`),
  and its one system applies them when their time comes.

  A scheduled change sets values on a component of any entity (a spring's flow,
  a hearth's fuel), which is why `edits/0` says `:any`: it is the one thing in
  a world that writes another rule's state on purpose, and it may only set what
  `Avwe.Definition.Schema.set_keys/1` lists for the component.
  """

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "sim"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:component, :place}, {:component, :miracle}]

  @impl Avwe.Rule
  def edits, do: :any

  @impl Avwe.Rule
  def provides, do: [:scheduled_changes]

  @impl Avwe.Rule
  def systems, do: [{"miracles", Avwe.Systems.Miracles}]
end
