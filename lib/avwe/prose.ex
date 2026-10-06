defmodule Avwe.Prose do
  @moduledoc """
  Plain-English text for percepts and looks. Every client can show these as
  they are; richer clients use the structured fields instead.
  """

  alias Avwe.Calendar

  @speech_verbs %{whisper: "whispers", talk: "says", shout: "shouts"}
  @own_speech_verbs %{whisper: "whisper", talk: "say", shout: "shout"}
  @warm_c 30
  @cool_air_c 15
  @warm_air_c 22

  @doc "Somebody asked for a body that another controller already holds."
  @spec body_taken(String.t()) :: String.t()
  def body_taken(name), do: "#{name} is already being played."

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

  # Lighting and dousing report themselves through the `:fire_lit` and
  # `:fire_out` percepts ("You light ..."), so a success says nothing more.
  def result(verb, :success, _reason, _target, _params) when verb in [:kindle, :douse], do: nil
  def result(:kindle, :blocked, :no_hearth, _target, _params), do: "There is no hearth here."
  def result(:douse, :blocked, :no_hearth, _target, _params), do: "There is no hearth here."

  # The target was not a hearth's id: a name that matched no hearth in reach
  # or in sight, or something that is not a hearth.
  def result(verb, :blocked, :no_such_hearth, _target, _params) when verb in [:kindle, :douse],
    do: "You find no hearth by that name within reach."

  def result(verb, :blocked, :too_far, _target, _params) when verb in [:kindle, :douse],
    do: "You are not close enough."

  def result(:kindle, :blocked, :no_fuel, _target, _params), do: "There is nothing to burn."
  def result(:kindle, :blocked, :already_burning, _target, _params), do: "It is already lit."
  def result(:douse, :blocked, :not_burning, _target, _params), do: "It isn't lit."
  def result(:douse, :failure, :unquenchable, _target, _params), do: "It does not go out."

  def result(:write, :success, _reason, target, _params), do: "You write in your #{target}."

  def result(:write, :blocked, :no_notebook, _target, _params),
    do: "You have nothing to write in."

  def result(:write, :blocked, :full, target, _params), do: "Your #{target} is full."

  def result(:write, :blocked, _reason, _target, _params),
    do: "You can't write that. A page holds 1 to 1000 characters."

  def result(:read, :blocked, :no_notebook, _target, _params), do: "You have nothing to read."

  def result(:read, :blocked, _reason, _target, _params),
    do: "You can't read like that. Read the last 1 to 50 pages."

  # Taking and releasing a body is the session's bookkeeping, not something
  # the body did, so nothing is said.
  def result(verb, :success, _reason, _target, _params) when verb in [:control, :release], do: nil
  def result(_verb, _outcome, _reason, _target, _params), do: "You can't do that."

  @doc """
  A body read the last pages of a notebook: a line saying how many, then one
  line per page with its world time, oldest first. The text is quoted as it
  was written; prose never interprets it.
  """
  @spec read(String.t(), [%{time: Calendar.time(), text: String.t()}], non_neg_integer()) ::
          String.t()
  def read(name, [], _total), do: "Your #{name} is empty."

  def read(name, pages, total) do
    lines = Enum.map(pages, &"  #{Calendar.format(&1.time)}: #{&1.text}")
    Enum.join(["You read your #{name} (#{length(pages)} of #{pages(total)}):" | lines], "\n")
  end

  defp pages(1), do: "1 page"
  defp pages(n), do: "#{n} pages"

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

  @doc "The body's controller let its routine take it, or took it back."
  @spec control(:control_released | :control_taken) :: String.t()
  def control(:control_released), do: "You let your routine carry you."
  def control(:control_taken), do: "You take yourself in hand."

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

  @doc """
  A fire was lit, burned low or went out. `who` is `:you` when the body did
  it, someone's name when they did, or `nil` when nobody did (the fuel ran
  out). A fire burning low or out on its own is "the fire" to a body at the
  hearth (`here?`) and named to anyone further off or watching.
  """
  @spec fire(
          :fire_lit | :fire_low | :fire_out,
          :you | String.t() | nil,
          String.t(),
          boolean()
        ) :: String.t()
  def fire(:fire_lit, :you, name, _here?), do: "You light #{name}."
  def fire(:fire_lit, who, name, _here?), do: "#{who} lights #{name}."
  def fire(:fire_low, _who, _name, true), do: "The fire burns low."
  def fire(:fire_low, _who, name, false), do: "#{capitalize(name)} burns low."
  def fire(:fire_out, nil, _name, true), do: "The fire goes out."
  def fire(:fire_out, nil, name, false), do: "The fire at #{name} goes out."
  def fire(:fire_out, :you, name, _here?), do: "You douse #{name}."
  def fire(:fire_out, who, name, _here?), do: "#{who} douses #{name}."

  @doc "The river's banks nearby began or stopped steaming. `near` names a place, for spectators."
  @spec steam(:steam_rising | :steam_fading, String.t() | nil) :: String.t()
  def steam(:steam_rising, nil), do: "Steam begins to rise from the banks."
  def steam(:steam_rising, near), do: "Steam begins to rise from the banks near #{near}."
  def steam(:steam_fading, nil), do: "The steam over the banks thins and is gone."

  def steam(:steam_fading, near),
    do: "The steam over the banks near #{near} thins and is gone."

  @doc """
  The body's nose caught woodsmoke on the wind, or lost it. `beside`, the
  name of a fire the body stands at, says where the smoke comes from
  instead of the wind.
  """
  @spec smell(:smoke_smelled | :smoke_faded, atom() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def smell(type, level, from, beside \\ nil)

  def smell(:smoke_smelled, :thick, _from, beside) when is_binary(beside),
    do: "The smoke from #{beside} beside you is thick."

  def smell(:smoke_smelled, _level, _from, beside) when is_binary(beside),
    do: "Woodsmoke rises from #{beside} beside you."

  def smell(:smoke_smelled, :faint, from, _beside),
    do: "You smell woodsmoke, faint, from the #{from}."

  def smell(:smoke_smelled, :clear, from, _beside),
    do: "You smell woodsmoke on the wind from the #{from}."

  def smell(:smoke_smelled, :thick, _from, _beside), do: "The smoke is thick here."
  def smell(:smoke_faded, _level, _from, _beside), do: "The smell of smoke fades."

  @doc "Describes a look (`Avwe.Perception.look/2`) as a few lines of text."
  @spec look(map()) :: String.t()
  def look(%{spectator: true} = look) do
    bodies = Enum.map(look.bodies, &spectated/1)

    fires =
      for %{burning: true, name: name} <- look[:fires] || [],
          do: "#{capitalize(name)} is burning."

    ([clock(look), "You are watching. Nobody can see you.", river_status(look[:river]) | bodies] ++
       fires)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def look(look) do
    [
      clock(look),
      away(look[:away] || [], look.time),
      you_are(look),
      look.here && look.here.description,
      ground(look[:ground], look[:channel]),
      channel(look[:channel]),
      air_and_ground(look[:warmth], look[:ground]),
      hearths(look[:hearths] || []),
      fire_felt(look[:warmth]),
      fires(look[:fires]),
      smoke(look[:smoke]),
      others(look.bodies),
      known(look.places),
      carried(look[:carried] || []),
      doing(look.action, look[:holder])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # What the body perceived while nobody held it, oldest first, each line
  # with its time, and the day too when it was not today.
  defp away([], _now), do: nil

  defp away(entries, now) do
    lines = Enum.map(entries, &"  #{stamp(&1.time, now)} #{&1.summary}")
    Enum.join(["While you were away:" | lines], "\n")
  end

  @doc """
  A moment as a player reads it beside a line of what happened: `HH:MM`,
  with the day when it was not the day of `now`, and the whole date when
  it was not the year.
  """
  @spec stamp(integer(), integer()) :: String.t()
  def stamp(time, now) do
    then = Calendar.describe(time)
    today = Calendar.describe(now)
    clock = "#{pad(then.hour)}:#{pad(then.minute)}"

    cond do
      then.year != today.year -> Calendar.format(time)
      then.day != today.day -> "day #{then.day}, #{clock}"
      true -> clock
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp carried([]), do: nil

  defp carried(items) do
    Enum.map_join(items, "\n", fn
      %{kind: :notebook, name: name, pages: 0} -> "You carry your #{name} (empty)."
      %{kind: :notebook, name: name, pages: pages} -> "You carry your #{name} (#{pages(pages)})."
      %{name: name} -> "You carry #{name}."
    end)
  end

  @doc """
  The time and the light, as a look begins: "1 AR, day 1, 12:25. It is
  daylight." A client that shows them apart from the look says it the same way.
  """
  @spec clock(map()) :: String.t()
  def clock(look), do: "#{Calendar.format(look.time)}. #{light(look.light)}"

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

  defp channel(nil), do: nil

  defp channel(%{at_head: true, flowing: false}),
    do: "This is where the old channel begins. Downstream it runs away from here."

  defp channel(channel) do
    where =
      if channel.distance_m <= 20,
        do: "runs here",
        else: "runs #{channel.distance_m} m to the #{channel.direction}"

    what =
      if channel.flowing,
        do: "The river #{where}#{channel_warmth(channel)}.",
        else: "The old channel #{where}."

    "#{what} Upstream is to the #{channel.upstream}, downstream to the #{channel.downstream}."
  end

  # Warm water steams when its reach's banks do (`channel.steaming`, the one
  # rule for steam): by day as much as by night, so the river never steams
  # while the silt beside it is said not to, or the other way round.
  defp channel_warmth(%{temp_c: temp} = channel) when is_number(temp) and temp >= @warm_c do
    if Map.get(channel, :steaming, false),
      do: ", warm, with steam lifting off it",
      else: ", warm"
  end

  defp channel_warmth(_channel), do: ""

  defp air_and_ground(nil, _ground), do: nil

  defp air_and_ground(warmth, ground) do
    sentences([
      air(warmth.air_c),
      warmth.ground && underfoot(warmth.ground),
      warmth.steam? && steam_off(ground)
    ])
  end

  defp air(air_c) when air_c < @cool_air_c, do: "The air is cool."
  defp air(air_c) when air_c >= @warm_air_c, do: "The air is warm."
  defp air(_mild), do: nil

  defp underfoot(:hot), do: "The ground is hot underfoot."
  defp underfoot(:warm), do: "The ground is warm underfoot."
  defp underfoot(:cold), do: "The ground is cold."

  defp steam_off(:silt), do: "Steam lifts off the silt."
  defp steam_off(:reeds), do: "Steam lifts off the reeds."
  defp steam_off(_bed), do: "Steam lifts off the water."

  # One line per hearth within reach, nearest first.
  defp hearths([]), do: nil
  defp hearths(hearths), do: Enum.map_join(hearths, "\n", &hearth/1)

  defp hearth(%{burning: true, name: name}), do: "#{capitalize(name)} is burning here."

  defp hearth(%{fuel_kg: fuel, name: name}) when fuel > 0,
    do: "#{capitalize(name)} is cold, with wood laid."

  defp hearth(%{name: name}), do: "#{capitalize(name)} is cold and empty."

  # Every fire whose warmth reaches the body, strongest first, in one line.
  defp fire_felt(%{sources: [_ | _] = sources}), do: Enum.map_join(sources, " ", &felt/1)
  defp fire_felt(%{fire: %{} = fire}), do: felt(fire)
  defp fire_felt(_warmth), do: nil

  defp felt(%{level: :hot}), do: "The fire's heat is on your face."
  defp felt(%{level: :warm, name: name}), do: "Warmth reaches you from #{name}."
  defp felt(%{level: :faint, name: name}), do: "You feel a faint warmth from #{name}."

  defp fires(fires) when fires in [nil, []], do: nil
  defp fires(fires), do: Enum.map_join(fires, "\n", &fire_sign/1)

  defp fire_sign(%{sign: :smoke} = fire),
    do: "Smoke rises from #{fire.name}, #{fire.distance_m} m to the #{fire.direction}."

  defp fire_sign(%{sign: :glow} = fire),
    do: "A glow shows at #{fire.name}, #{fire.distance_m} m to the #{fire.direction}."

  defp smoke(nil), do: nil
  defp smoke(%{level: :thick, beside: %{name: name}}), do: "The smoke from #{name} is thick."
  defp smoke(%{beside: %{name: name}}), do: "Woodsmoke rises from #{name} beside you."
  defp smoke(%{level: :faint, from: from}), do: "Woodsmoke, faint, from the #{from}."
  defp smoke(%{level: :clear, from: from}), do: "Woodsmoke on the wind from the #{from}."
  defp smoke(%{level: :thick}), do: "The smoke is thick here."

  # Joins the sentences that are there into one line, or nothing.
  defp sentences(parts) do
    case Enum.filter(parts, &is_binary/1) do
      [] -> nil
      present -> Enum.join(present, " ")
    end
  end

  defp others([]), do: "You see no one else."
  defp others(bodies), do: Enum.map_join(bodies, "\n", &other/1)

  defp other(%{here: true, name: name}), do: "#{name} is here."
  defp other(other), do: "You see #{other.name}, #{other.distance_m} m to the #{other.direction}."

  defp known([]), do: nil

  defp known(places) do
    listed = Enum.map_join(places, ", ", &"#{&1.name} (#{&1.distance_m} m #{&1.direction})")
    "You know the way to: #{listed}."
  end

  # What the body is doing is its routine's while nobody holds it (`holder`
  # is `nil`) and the controller's own while one does, whoever asked for
  # it: a wait the routine began reads as the player's once they have the
  # body, and a journey they began as the routine's once they have let go.
  defp doing(nil, _holder), do: nil

  defp doing(%{verb: :go, target_name: target}, nil),
    do: "Your routine has you on your way to #{target}."

  defp doing(%{verb: :go, target_name: target}, _holder), do: "You are on your way to #{target}."

  defp doing(%{verb: :follow, params: %{direction: direction}}, nil),
    do: "Your routine has you following the channel #{direction}."

  defp doing(%{verb: :follow, params: %{direction: direction}}, _holder),
    do: "You are following the channel #{direction}."

  defp doing(%{verb: :walk, params: %{direction: direction}}, nil),
    do: "Your routine has you walking #{direction}."

  defp doing(%{verb: :walk, params: %{direction: direction}}, _holder),
    do: "You are walking #{direction}."

  defp doing(%{verb: :wait} = action, holder) do
    case {holder, until_dawn?(action)} do
      {nil, true} -> "Your routine has you resting until dawn."
      {nil, false} -> "Your routine has you waiting here."
      {_held, true} -> "You are resting until dawn."
      {_held, false} -> "You are waiting here a while."
    end
  end

  defp doing(_action, _holder), do: nil

  defp until_dawn?(%{params: %{until: moment}}), do: moment in [:dawn, :sunrise]
  defp until_dawn?(_action), do: false

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
