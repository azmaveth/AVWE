defmodule Avwe.Command do
  @moduledoc """
  What a player types, and what it means. Pure, and no client's own: telnet
  and the web page use it.

    * `parse/1` reads one line of input.
    * `resolve/2` matches a name typed against places, bodies, hearths and
      worlds.
    * `interpret/2` says what a parsed command asks for, given the player's
      look: an act with its names resolved, or a refusal in words.
    * `help/0` lists the commands.
  """

  @help """
  Commands:
    look              describe where you are
    go <place>        walk to a place you know
    go <direction>    walk 100 m north, south-east... (or: go west 300)
    follow upstream   follow the river channel (or: follow downstream)
    say <text>        speak (also: whisper, shout)
    wait [minutes]    let time pass (also: wait 2 hours, wait until dawn, wait until dusk)
    kindle [hearth]   light the hearth here (also: light the fire, light the lodge hearth)
    douse [hearth]    put the fire out (also: put out the fire, douse the coal)
    write <text>      write a page in your notebook
    read [pages]      read the last pages of your notebook (also: notes)
    stop              stop what you're doing
    time              the time in the world
    quit              leave\
  """

  @default_wait_minutes 10
  @compass %{
    "n" => "north",
    "north" => "north",
    "ne" => "north-east",
    "northeast" => "north-east",
    "e" => "east",
    "east" => "east",
    "se" => "south-east",
    "southeast" => "south-east",
    "s" => "south",
    "south" => "south",
    "sw" => "south-west",
    "southwest" => "south-west",
    "w" => "west",
    "west" => "west",
    "nw" => "north-west",
    "northwest" => "north-west"
  }
  @moments %{
    "dawn" => :dawn,
    "sunrise" => :dawn,
    "morning" => :dawn,
    "dusk" => :dusk,
    "sunset" => :dusk,
    "evening" => :dusk
  }

  @type t ::
          :look
          | {:go, String.t()}
          | {:follow, :upstream | :downstream}
          | {:walk, String.t(), pos_integer()}
          | {:say, :whisper | :talk | :shout, String.t()}
          | {:wait, map()}
          | :stop
          | {:kindle, String.t() | nil}
          | {:douse, String.t() | nil}
          | {:write, String.t()}
          | {:read, pos_integer() | nil}
          | :time
          | :help
          | :quit
          | :empty
          | {:invalid, String.t()}
          | {:unknown, String.t()}

  @typedoc """
  What `interpret/2` says to do: an act for `Avwe.Session.act/3`; one of the
  answers a client gives in its own way (`:look`, `:time`, `:help`, `:quit`);
  nothing at all (`:noop`); or a refusal, in the words a player is shown.
  """
  @type outcome ::
          {:act, atom(), keyword()}
          | :look
          | :time
          | :help
          | :quit
          | :noop
          | {:error, String.t()}

  @doc """
  Parses one line of input.

      iex> Avwe.Command.parse("go to the dry bend")
      {:go, "the dry bend"}

      iex> Avwe.Command.parse("wait until dawn")
      {:wait, %{until: :dawn}}

  Kindling and dousing take an optional hearth name: `kindle`, `light the
  fire` and `put out the fire` mean the nearest hearth (`nil`); `douse the
  coal`, `light the lodge hearth` and `put out the fire in the kiln-house
  hearth` name one.

      iex> Avwe.Command.parse("light the fire")
      {:kindle, nil}

      iex> Avwe.Command.parse("put out the fire in the kiln-house hearth")
      {:douse, "kiln-house hearth"}

  Writing keeps the text as typed; reading takes an optional number of
  pages (`nil` for the world's default), and `notes` is reading.

      iex> Avwe.Command.parse("write The reeds lean North.")
      {:write, "The reeds lean North."}

      iex> Avwe.Command.parse("read 3")
      {:read, 3}
  """
  @spec parse(String.t()) :: t()
  def parse(line) do
    line = String.trim(line)

    case String.split(line, ~r/\s+/, parts: 2) do
      [""] -> :empty
      [word] -> command(String.downcase(word), "", line)
      [word, rest] -> command(String.downcase(word), String.trim(rest), line)
    end
  end

  defp command(word, _rest, _line) when word in ["look", "l"], do: :look
  defp command(word, "", _line) when word in ["go", "walk"], do: {:invalid, "Go where?"}

  defp command(word, rest, _line) when word in ["go", "walk"] do
    rest = strip_prefix(rest, "to ")

    case {follow(rest), walk(String.downcase(rest))} do
      {{:follow, _direction} = follow, _walk} -> follow
      {_follow, {:walk, _direction, _meters} = walk} -> walk
      _place -> {:go, rest}
    end
  end

  defp command("follow", rest, _line) do
    case follow(rest) do
      {:follow, _direction} = follow -> follow
      :none -> {:invalid, "Follow the channel upstream or downstream?"}
    end
  end

  defp command("say", rest, _line), do: speech(:talk, rest)
  defp command("whisper", rest, _line), do: speech(:whisper, rest)
  defp command("shout", rest, _line), do: speech(:shout, rest)
  defp command("wait", rest, _line), do: wait(String.downcase(rest))
  defp command("stop", _rest, _line), do: :stop

  defp command(word, rest, _line) when word in ["kindle", "light"],
    do: {:kindle, hearth_name(rest)}

  defp command("douse", rest, _line), do: {:douse, hearth_name(rest)}

  defp command("put", rest, line) do
    if String.downcase(rest) == "out" or String.starts_with?(String.downcase(rest), "out "),
      do: {:douse, rest |> strip_prefix("out") |> hearth_name()},
      else: {:unknown, line}
  end

  defp command("write", "", _line), do: {:invalid, "Write what?"}
  defp command("write", rest, _line), do: {:write, rest}
  defp command("notes", _rest, _line), do: {:read, nil}
  defp command("read", "", _line), do: {:read, nil}

  defp command("read", rest, _line) do
    case Integer.parse(rest) do
      {n, ""} when n > 0 -> {:read, n}
      _other -> {:invalid, "Read how many pages? Try: read, read 5."}
    end
  end

  defp command("time", _rest, _line), do: :time
  defp command(word, _rest, _line) when word in ["help", "?"], do: :help
  defp command(word, _rest, _line) when word in ["quit", "exit"], do: :quit
  defp command(_word, _rest, line), do: {:unknown, line}

  # "upstream", "the channel upstream", "river down"...
  defp follow(text) do
    words = text |> String.downcase() |> String.split(~r/\W+/, trim: true)

    cond do
      Enum.any?(words, &(&1 in ["upstream", "up"])) -> {:follow, :upstream}
      Enum.any?(words, &(&1 in ["downstream", "down"])) -> {:follow, :downstream}
      true -> :none
    end
  end

  # "north", "ne", "north-east 200", "west 50 m"...
  defp walk(text) do
    case Regex.run(~r/^([a-z-]+)(?:\s+(\d+)\s*(?:m|metres|meters)?)?$/, text) do
      [_all, direction] -> walk_to(direction, "100")
      [_all, direction, meters] -> walk_to(direction, meters)
      nil -> :none
    end
  end

  defp walk_to(direction, meters) do
    case Map.fetch(@compass, String.replace(direction, "-", "")) do
      {:ok, compass} -> {:walk, compass, String.to_integer(meters)}
      :error -> :none
    end
  end

  defp speech(volume, ""), do: {:invalid, "#{volume |> verb() |> String.capitalize()} what?"}
  defp speech(volume, text), do: {:say, volume, text}

  defp verb(:talk), do: "say"
  defp verb(volume), do: Atom.to_string(volume)

  defp wait(""), do: {:wait, %{for: @default_wait_minutes * 60}}

  defp wait(arg) do
    arg = arg |> strip_prefix("until ") |> strip_prefix("till ") |> strip_prefix("for ")

    case Map.fetch(@moments, arg) do
      {:ok, moment} -> {:wait, %{until: moment}}
      :error -> wait_duration(Integer.parse(arg))
    end
  end

  defp wait_duration({n, unit}) when n > 0 do
    case String.trim(unit) do
      u when u in ["", "m", "min", "mins", "minute", "minutes"] -> {:wait, %{for: n * 60}}
      u when u in ["h", "hour", "hours"] -> {:wait, %{for: n * 3_600}}
      _other -> wait_help()
    end
  end

  defp wait_duration(_other), do: wait_help()

  defp wait_help, do: {:invalid, "Wait how long? Try: wait 30, wait 2 hours, wait until dawn."}

  # The hearth a player named after kindle, light, douse or put out, or nil
  # for the nearest: "the fire", "the hearth" and "the fire in the ..." are
  # ways of saying it, not names.
  # "the coal", "the fire in the lodge hearth", "fire" (meaning the nearest)...
  defp hearth_name(rest) do
    name =
      rest
      |> String.downcase()
      |> String.replace(~r/^(the\s+)?fire(\s+(in|at))?\b/, "")
      |> String.replace(~r/^\s*the\b/, "")
      |> String.trim()

    if name in ["", "the", "fire", "hearth"], do: nil, else: name
  end

  defp strip_prefix(text, prefix) do
    if String.starts_with?(String.downcase(text), prefix),
      do: text |> String.slice(String.length(prefix)..-1//1) |> String.trim(),
      else: text
  end

  @doc """
  The commands, in the words a player is told them: what `help` says. A client
  adds what is its own (telnet explains its marked lines).
  """
  @spec help() :: String.t()
  def help, do: @help

  @doc """
  Whether `interpret/2` reads the player's look for this command: `go`, whose
  places are the ones the body knows, and `kindle` or `douse` with a hearth
  named, whose hearths are the ones within reach. For any other command the
  look may be `nil`.
  """
  @spec needs_look?(t()) :: boolean()
  def needs_look?({:go, _query}), do: true
  def needs_look?({verb, query}) when verb in [:kindle, :douse] and is_binary(query), do: true
  def needs_look?(_command), do: false

  @doc """
  What a parsed command asks for, given the player's `look` (`Avwe.Session.look/1`).

    * `{:act, verb, opts}` is for `Avwe.Session.act/3`, with a place or hearth
      already resolved to its id.
    * `:look`, `:time`, `:help` and `:quit` are answered by the client in its
      own way. `:time` and `:help` are the player's presence rather than an
      act: the client touches the session (`Avwe.Session.touch/1`) for them.
    * `:noop` is an empty line.
    * `{:error, message}` is a refusal in the words to show: a name that
      matches nothing or several things, a command that was not understood, a
      spectator who tried to light a fire. A spectator's other acts are
      refused by the session itself (`{:error, :spectator}`).

      iex> look = %{places: [%{id: "the-dry-bend", name: "The Dry Bend"}]}
      iex> Avwe.Command.interpret({:go, "dry bend"}, look)
      {:act, :go, [target: "the-dry-bend"]}
      iex> Avwe.Command.interpret({:go, "atlantis"}, look)
      {:error, ~s(You don't know a place called "atlantis".)}
  """
  @spec interpret(t(), map() | nil) :: outcome()
  def interpret(:look, _look), do: :look
  def interpret(:time, _look), do: :time
  def interpret(:help, _look), do: :help
  def interpret(:quit, _look), do: :quit
  def interpret(:empty, _look), do: :noop
  def interpret(:stop, _look), do: {:act, :stop, []}
  def interpret({:invalid, message}, _look), do: {:error, message}

  def interpret({:unknown, line}, _look),
    do: {:error, "I don't understand \"#{line}\". Type help for a list of commands."}

  def interpret({:follow, direction}, _look), do: {:act, :follow, params: %{direction: direction}}

  def interpret({:walk, direction, meters}, _look),
    do: {:act, :walk, params: %{direction: direction, distance_m: meters}}

  def interpret({:say, volume, text}, _look),
    do: {:act, :say, params: %{text: text, volume: volume}}

  def interpret({:wait, params}, _look), do: {:act, :wait, params: params}
  def interpret({:write, text}, _look), do: {:act, :write, params: %{text: text}}
  def interpret({:read, nil}, _look), do: {:act, :read, params: %{}}
  def interpret({:read, pages}, _look), do: {:act, :read, params: %{last: pages}}

  def interpret({:go, query}, look) do
    places = Enum.map(look[:places] || [], &{&1.id, &1.name}) ++ here(look)

    case resolve(query, places) do
      {:ok, place} -> {:act, :go, target: place}
      {:ambiguous, names} -> {:error, which(names)}
      :none -> {:error, ~s(You don't know a place called "#{query}".)}
    end
  end

  def interpret({verb, nil}, _look) when verb in [:kindle, :douse], do: {:act, verb, []}

  # A named hearth is one of those within reach: the world answers for the
  # nearest when none is named, never when a name matches nothing.
  def interpret({verb, query}, look) when verb in [:kindle, :douse] do
    hearths = Enum.map(look[:hearths] || [], &{&1.id, &1.name})

    if look[:spectator],
      do: {:error, "You're only watching."},
      else: hearth(resolve(query, hearths), verb, query)
  end

  defp hearth({:ok, id}, verb, _query), do: {:act, verb, target: id}
  defp hearth({:ambiguous, names}, _verb, _query), do: {:error, which(names)}
  defp hearth(:none, _verb, query), do: {:error, ~s(There is no hearth called "#{query}" here.)}

  defp which(names), do: "Which do you mean: #{Enum.join(names, ", ")}?"

  defp here(%{here: %{id: id, name: name}}), do: [{id, name}]
  defp here(_look), do: []

  @doc """
  Matches a name someone typed against `{id, name}` candidates. Case, spacing
  and a leading "the" don't matter, and any part of a name will do.

      iex> Avwe.Command.resolve("dry bend", [{"the-dry-bend", "The Dry Bend"}, {"willow-docks", "Willow Docks"}])
      {:ok, "the-dry-bend"}
  """
  @spec resolve(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:ambiguous, [String.t()]} | :none
  def resolve(query, candidates) do
    query = normalize(query)

    exact = Enum.filter(candidates, fn {id, name} -> normalize(name) == query or id == query end)

    partial =
      Enum.filter(candidates, fn {id, name} ->
        String.contains?(normalize(name), query) or String.starts_with?(id, query)
      end)

    case {exact, partial} do
      {[{id, _name}], _partial} -> {:ok, id}
      {[], [{id, _name}]} -> {:ok, id}
      {[], []} -> :none
      {[], many} -> {:ambiguous, Enum.map(many, &elem(&1, 1))}
      {many, _partial} -> {:ambiguous, Enum.map(many, &elem(&1, 1))}
    end
  end

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> strip_prefix("the ")
    |> String.replace(~r/\s+/, " ")
  end
end
