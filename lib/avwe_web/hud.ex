defmodule AvweWeb.Hud do
  @moduledoc """
  What the play page offers a click: the time and the light, and buttons for
  what the body can do right now. Pure, and built from the look alone.

  The look's `affordances` say what the body can do (go to a place it knows,
  light or douse a hearth it stands by, stop what it is doing, wait, read its
  notebook), and the places and hearths it lists say what to call each. A
  button is a label and a command line: pressing one is typing that line, so
  the command line is the one way into the world, and what a button may do is
  what a typed line may do, no more.
  """

  alias Avwe.Prose

  @type button :: %{label: String.t(), line: String.t()}
  @type group :: %{title: String.t(), buttons: [button()]}
  @type t :: %{clock: String.t(), groups: [group()]}

  @doc "The HUD of a look: its clock, and its groups of buttons that are not empty."
  @spec build(map()) :: t()
  def build(look) do
    groups = [places(look), fire(look), actions(look)]
    %{clock: Prose.clock(look), groups: Enum.reject(groups, &(&1.buttons == []))}
  end

  defp places(look) do
    known = Map.new(look.places, &{&1.id, &1})

    buttons =
      for %{verb: :go, targets: targets} <- affordances(look),
          id <- targets,
          place = known[id],
          do: %{
            label: "#{place.name} (#{place.distance_m} m #{place.direction})",
            line: "go to #{id}"
          }

    %{title: "Places", buttons: buttons}
  end

  defp fire(look) do
    hearths = Map.new(look.hearths, &{&1.id, &1})

    buttons =
      for %{verb: verb, targets: targets} <- affordances(look),
          verb in [:kindle, :douse],
          id <- targets,
          hearth = hearths[id],
          do: %{label: "#{fire_verb(verb)} #{hearth.name}", line: "#{verb} #{id}"}

    %{title: "Fire", buttons: buttons}
  end

  defp fire_verb(:kindle), do: "Light"
  defp fire_verb(:douse), do: "Put out"

  defp actions(look) do
    affordances = affordances(look)

    buttons =
      [
        for(%{verb: :stop} <- affordances, do: %{label: "Stop", line: "stop"}),
        for(%{verb: :wait, until: moments} <- affordances, button <- waits(moments), do: button),
        for(%{verb: :read} <- affordances, do: %{label: "Read your notebook", line: "read"})
      ]
      |> List.flatten()

    %{title: "Actions", buttons: buttons}
  end

  defp waits(moments) do
    [%{label: "Wait", line: "wait"}] ++
      for moment <- moments, do: %{label: "Wait until #{moment}", line: "wait until #{moment}"}
  end

  defp affordances(look), do: Map.get(look, :affordances, [])
end
