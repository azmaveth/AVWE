defmodule Avwe.Prose do
  @moduledoc """
  Plain-English text for percepts and looks. Every client can show these as
  they are; richer clients use the structured fields instead.
  """

  alias Avwe.Calendar

  @speech_verbs %{whisper: "whispers", talk: "says", shout: "shouts"}
  @own_speech_verbs %{whisper: "whisper", talk: "say", shout: "shout"}

  @doc "A body has started an action of its own."
  @spec started(atom(), String.t() | nil, map()) :: String.t()
  def started(:go, target, _params), do: "You set off toward #{target}."

  def started(:wait, _target, %{until: moment}),
    do: "You settle in to wait for #{moment(moment)}."

  def started(:wait, _target, _params), do: "You settle in to wait."
  def started(_verb, _target, _params), do: "You begin."

  @doc "A body's own walk has reached a quarter mark."
  @spec progress(String.t() | nil, float()) :: String.t()
  def progress(target, 0.25), do: "You're a quarter of the way to #{target}."
  def progress(target, 0.5), do: "You're halfway to #{target}."
  def progress(target, _quarter), do: "You're nearly at #{target}."

  @doc """
  An intent has finished. Returns `nil` when another percept already says what
  happened (a `stop` whose stopped action reports itself).
  """
  @spec result(atom(), atom(), atom() | nil, String.t() | nil, map()) :: String.t() | nil
  def result(_verb, :blocked, :no_such_body, _target, _params), do: "You have no body here."
  def result(:go, :success, :already_there, target, _params), do: "You're already at #{target}."
  def result(:go, :success, _reason, target, _params), do: "You arrive at #{target}."
  def result(:go, :blocked, _reason, _target, _params), do: "You don't know the way there."
  def result(:go, :interrupted, :stopped, target, _params), do: "You stop short of #{target}."

  def result(:go, :interrupted, _reason, target, _params),
    do: "You give up on going to #{target}."

  def result(:wait, :success, _reason, _target, _params), do: "You finish waiting."
  def result(:wait, :interrupted, _reason, _target, _params), do: "You stop waiting."
  def result(:wait, :blocked, _reason, _target, _params), do: "You can't wait like that."

  def result(:say, :success, _reason, _target, %{text: text, volume: volume}),
    do: "You #{@own_speech_verbs[volume]}, \"#{text}\""

  def result(:say, :blocked, _reason, _target, _params), do: "You can't say that."
  def result(:stop, :success, :idle, _target, _params), do: "You aren't doing anything."
  def result(:stop, :success, _reason, _target, _params), do: nil
  def result(_verb, _outcome, _reason, _target, _params), do: "You can't do that."

  @doc "Someone was heard speaking. `direction` is set when they are some way off."
  @spec heard(String.t(), atom(), String.t(), String.t() | nil) :: String.t()
  def heard(who, volume, text, nil), do: "#{who} #{@speech_verbs[volume]}, \"#{text}\""

  def heard(who, volume, text, direction),
    do: "#{who} #{@speech_verbs[volume]} from the #{direction}, \"#{text}\""

  @doc "Someone was seen leaving for, or arriving at, a place."
  @spec moving(:departed | :arrived, String.t(), String.t() | nil) :: String.t()
  def moving(:departed, who, toward), do: "#{who} leaves, heading toward #{toward}."
  def moving(:arrived, who, place), do: "#{who} arrives at #{place}."

  @doc "Something happened in the sky."
  @spec sky(:sunrise | :sunset) :: String.t()
  def sky(:sunrise), do: "The sun rises."
  def sky(:sunset), do: "The sun sets."

  @doc "Describes a look (`Avwe.Perception.look/2`) as a few lines of text."
  @spec look(map()) :: String.t()
  def look(%{spectator: true} = look) do
    bodies = Enum.map(look.bodies, &spectated/1)
    Enum.join([clock(look), "You are watching. Nobody can see you." | bodies], "\n")
  end

  def look(look) do
    [
      clock(look),
      you_are(look),
      look.here && look.here.description,
      others(look.bodies),
      known(look.places),
      doing(look.action)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp clock(look), do: "#{Calendar.format(look.time)}. #{light(look.light)}"

  defp light(level) when level == 0, do: "It is dark."
  defp light(level) when level < 0.25, do: "The light is low."
  defp light(_level), do: "It is daylight."

  defp you_are(%{body: body, here: %{name: place}}), do: "You are #{body.name}, at #{place}."

  defp you_are(%{body: body, nearest: %{} = nearest}),
    do: "You are #{body.name}, #{nearest.distance_m} m #{nearest.direction} of #{nearest.name}."

  defp you_are(%{body: body}), do: "You are #{body.name}."

  defp others([]), do: "You see no one else."

  defp others(bodies), do: Enum.map_join(bodies, "\n", &other/1)

  defp other(%{here: true, name: name}), do: "#{name} is here."
  defp other(other), do: "You see #{other.name}, #{other.distance_m} m to the #{other.direction}."

  defp known([]), do: nil

  defp known(places) do
    listed = Enum.map_join(places, ", ", &"#{&1.name} (#{&1.distance_m} m #{&1.direction})")
    "You know the way to: #{listed}."
  end

  defp doing(nil), do: nil
  defp doing(%{verb: :go, target_name: target}), do: "You are on your way to #{target}."
  defp doing(%{verb: :wait}), do: "You are waiting."
  defp doing(_action), do: nil

  defp spectated(body) do
    where =
      cond do
        body.going_to -> "on the way to #{body.going_to}"
        body.at -> "at #{body.at}"
        body.near -> "near #{body.near}"
        true -> "somewhere"
      end

    "#{body.name} is #{where}."
  end

  defp moment(moment) when moment in [:dawn, :sunrise], do: "dawn"
  defp moment(moment) when moment in [:dusk, :sunset], do: "dusk"
  defp moment(moment), do: to_string(moment)
end
