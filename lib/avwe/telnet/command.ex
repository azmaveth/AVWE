defmodule Avwe.Telnet.Command do
  @moduledoc """
  Parses what a telnet player types, and matches names they type against
  places, bodies and worlds. Pure.
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
          | :time
          | :help
          | :quit
          | :empty
          | {:invalid, String.t()}
          | {:unknown, String.t()}

  @doc """
  Parses one line of input.

      iex> Avwe.Telnet.Command.parse("go to the dry bend")
      {:go, "the dry bend"}

      iex> Avwe.Telnet.Command.parse("wait until dawn")
      {:wait, %{until: :dawn}}
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

  defp strip_prefix(text, prefix) do
    if String.starts_with?(String.downcase(text), prefix),
      do: text |> String.slice(String.length(prefix)..-1//1) |> String.trim(),
      else: text
  end

  @doc """
  Matches a name someone typed against `{id, name}` candidates. Case, spacing
  and a leading "the" don't matter, and any part of a name will do.

      iex> Avwe.Telnet.Command.resolve("dry bend", [{"the-dry-bend", "The Dry Bend"}, {"willow-docks", "Willow Docks"}])
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
