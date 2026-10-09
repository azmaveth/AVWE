defmodule Avwe.Rules.Earthlike.Daylight do
  @moduledoc "The sun: the light of the day, and the moments of sunrise and sunset."

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.daylight"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [{:env, :light}]

  @impl Avwe.Rule
  def provides, do: [:light]

  # Before the bodies act, who see the light of the step.
  @impl Avwe.Rule
  def systems, do: [{"step", Avwe.Systems.Daylight, runs_before: ["play/movement"]}]
end
