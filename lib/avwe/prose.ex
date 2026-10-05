defmodule Avwe.Prose do
  @moduledoc """
  Plain-English text for percepts and looks. Every client can show these as
  they are; richer clients use the structured fields instead.
  """

  alias Avwe.Calendar
  alias Avwe.Systems.River

  @speech_verbs %{whisper: "whispers", talk: "says", shout: "shouts"}
  @own_speech_verbs %{whisper: "whisper", talk: "say", shout: "shout"}
  @warm_c 30
  @steam_above_air_c 15

  @doc "A body has started an action of its own."
  @spec started(atom(), String.t() | nil, map()) :: String.t()
  def started(:go, target, _params), do: "You set off toward #{target}."

  def started(:follow, _target, %{direction: direction}),
    do: "You set off #{direction} along the channel."

  def started(:walk, _target, %{direction: direction}), do: "You set off to the #{direction}."

  def started(:wait, _target, %{until: moment}),
    do: "You settle in to wait for #{moment(moment)}."

  def started(:wait, _target, _params), do: "You settle in to wait."
  def started(_verb, _target, _params), do: "You begin."

  @doc "A body's own journey has reached a quarter mark."
  @spec progress(atom(), String.t() | nil, map(), float()) :: String.t()
  def progress(:go, target, _params, 0.25), do: "You're a quarter of the way to #{target}."
  def progress(:go, target, _params, 0.5), do: "You're halfway to #{target}."
  def progress(:go, target, _params, _quarter), do: "You're nearly at #{target}."
  def progress(:follow, _target, _params, 0.25), do: "You follow the channel on."
  def progress(:follow, _target, _params, 0.5), do: "You keep to the channel."
  def progress(:follow, _target, _params, _quarter), do: "The channel goes on a little further."
  def progress(_verb, _target, _params, 0.5), do: "You're halfway there."
  def progress(_verb, _target, _params, _quarter), do: "You keep walking."

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

  def result(:follow, :success, _reason, _target, %{direction: :upstream}),
    do: "You reach the head of the channel."

  def result(:follow, :success, _reason, _target, _params),
    do: "You follow the channel to the edge of the valley."

  def result(:follow, :blocked, :no_channel, _target, _params),
    do: "There's no channel here to follow."

  def result(:follow, :blocked, _reason, _target, _params),
    do: "Follow it upstream or downstream?"

  def result(:follow, :interrupted, _reason, _target, _params),
    do: "You stop following the channel."

  def result(:walk, :success, _reason, _target, %{direction: direction, distance_m: meters}),
    do: "You stop, #{meters} m #{direction} of where you set out."

  def result(:walk, :blocked, :edge, _target, _params),
    do: "You can't go any further that way."

  def result(:walk, :blocked, _reason, _target, _params), do: "You can't walk like that."
  def result(:walk, :interrupted, _reason, _target, _params), do: "You stop walking."
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

  @doc """
  Someone was seen leaving or arriving. `toward` is a place name, or a heading
  such as "upstream" or "north" when `heading?` is true.
  """
  @spec moving(:departed | :arrived, String.t(), String.t() | nil, boolean()) :: String.t()
  def moving(:departed, who, heading, true), do: "#{who} leaves, heading #{heading}."
  def moving(:departed, who, toward, false), do: "#{who} leaves, heading toward #{toward}."
  def moving(:arrived, who, place, _heading?), do: "#{who} arrives at #{place}."

  @doc "Something happened in the sky."
  @spec sky(:sunrise | :sunset) :: String.t()
  def sky(:sunrise), do: "The sun rises."
  def sky(:sunset), do: "The sun sets."

  @doc "The river nearby fell silent or started running. `near` names a place, for spectators."
  @spec river(:river_silent | :river_flowing, String.t() | nil) :: String.t()
  def river(:river_silent, nil), do: "The river falls silent."
  def river(:river_silent, near), do: "The river falls silent near #{near}."
  def river(:river_flowing, nil), do: "Water begins to run in the channel."
  def river(:river_flowing, near), do: "Water begins to run in the channel near #{near}."

  @doc "The spring at the river's source stopped or started."
  @spec spring(:spring_stopped | :spring_started) :: String.t()
  def spring(:spring_stopped), do: "The spring stops welling up."
  def spring(:spring_started), do: "Water wells up in the spring."

  @doc "A body found a place it didn't know."
  @spec discovered(String.t(), String.t() | nil) :: String.t()
  def discovered(name, nil), do: "You find #{name}."
  def discovered(name, description), do: "You find #{name}. #{description}"

  @doc "Describes a look (`Avwe.Perception.look/2`) as a few lines of text."
  @spec look(map()) :: String.t()
  def look(%{spectator: true} = look) do
    bodies = Enum.map(look.bodies, &spectated/1)

    [clock(look), "You are watching. Nobody can see you.", river_status(look[:river]) | bodies]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def look(look) do
    [
      clock(look),
      you_are(look),
      look.here && look.here.description,
      ground(look[:ground], look[:channel]),
      channel(look[:channel], look.light),
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

  defp ground(nil, _channel), do: nil
  defp ground(:channel_bed, %{flowing: true}), do: "You are standing in the river."
  defp ground(:channel_bed, _channel), do: "You stand in the old river channel, on cracked mud."
  defp ground(:reeds, %{flowing: true}), do: "Reeds crowd the river's edge here."
  defp ground(:reeds, _channel), do: "Reeds stand around you, keeping the channel's shape."
  defp ground(:silt, _channel), do: "The ground is silt, pale and fine."
  defp ground(:clay, _channel), do: "The ground underfoot is packed clay."
  defp ground(:stone, _channel), do: "Pale stone breaks through the thin soil."
  defp ground(:grass, _channel), do: "Dry grass covers the ground."

  defp channel(nil, _light), do: nil

  defp channel(%{at_head: true, flowing: false}, _light),
    do: "This is where the old channel begins. Downstream it runs away from here."

  defp channel(channel, light) do
    where =
      if channel.distance_m <= 20,
        do: "runs here",
        else: "runs #{channel.distance_m} m to the #{channel.direction}"

    what =
      if channel.flowing,
        do: "The river #{where}#{warmth(channel, light)}.",
        else: "The old channel #{where}."

    "#{what} Upstream is to the #{channel.upstream}, downstream to the #{channel.downstream}."
  end

  defp warmth(%{temp_c: temp}, light) when is_number(temp) and temp >= @warm_c do
    if light < 0.3 and temp - River.ambient_c() >= @steam_above_air_c,
      do: ", warm, with steam lifting off it",
      else: ", warm"
  end

  defp warmth(_channel, _light), do: ""

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

  defp doing(%{verb: :follow, params: %{direction: direction}}),
    do: "You are following the channel #{direction}."

  defp doing(%{verb: :walk, params: %{direction: direction}}), do: "You are walking #{direction}."
  defp doing(%{verb: :wait}), do: "You are waiting."
  defp doing(_action), do: nil

  defp river_status(nil), do: nil
  defp river_status(%{flowing: 0, name: name}), do: "#{capitalize(name)} is dry."

  defp river_status(%{flowing: all, reaches: all, name: name}),
    do: "#{capitalize(name)} is running."

  defp river_status(%{name: name}), do: "#{capitalize(name)} is running in places."

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

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp moment(moment) when moment in [:dawn, :sunrise], do: "dawn"
  defp moment(moment) when moment in [:dusk, :sunset], do: "dusk"
  defp moment(moment), do: to_string(moment)
end
