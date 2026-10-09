defmodule Avwe.Rules.Play do
  @moduledoc """
  The agent layer as a rule: bodies, what they are doing, what they know and
  remember, and the systems that carry their actions out (timed actions,
  movement, discovery, memory and the autopilot). A world with bodies lists it.

  `uses` says what the engine still reaches for by name, which E3 to E5 turn
  into the embodiments of the rules that own it: the autopilot's candidates
  look for hearths and the river's temperature.
  """

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "play"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns do
    for name <-
          ~w(position repr body control action knows memory notebook item carried_by autopilot routine norms guest)a,
        do: {:component, name}
  end

  @impl Avwe.Rule
  def provides, do: [:bodies, :intents]

  @impl Avwe.Rule
  def uses, do: [:air_temperature, :fire_sources, :light, :river_water]

  # In this order, which the physics rules fit themselves around (they say
  # what they run before; the engine names none of them).
  @impl Avwe.Rule
  def systems do
    [
      {"movement", Avwe.Systems.Movement},
      {"waiting", Avwe.Systems.Waiting},
      {"discovery", Avwe.Systems.Discovery},
      {"autopilot", Avwe.Systems.Autopilot},
      {"memory", Avwe.Systems.Memory}
    ]
  end
end
