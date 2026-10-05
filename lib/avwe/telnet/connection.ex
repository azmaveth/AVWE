defmodule Avwe.Telnet.Connection do
  @moduledoc """
  One telnet player.

  Greets them, has them choose a world if more than one is running, then a
  body (or to watch). After that it turns their commands into intents and
  their percepts into lines of text. Everything goes through an
  `Avwe.Session`, like any other controller.
  """

  use GenServer, restart: :temporary

  alias Avwe.{Prose, Session}
  alias Avwe.Telnet.Command

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
    stop              stop what you're doing
    time              the time in the world
    quit              leave\
  """

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @impl true
  def init(socket) do
    {:ok, %{socket: socket, phase: :starting, world: nil, session: nil}}
  end

  @impl true
  def handle_info(:socket_ready, state) do
    state |> greet() |> continue()
  end

  def handle_info({:tcp, _socket, data}, state) do
    state |> handle_line(clean(data)) |> continue()
  end

  def handle_info({:avwe_percepts, _session, percepts}, state) do
    for %{summary: summary} when is_binary(summary) <- percepts, do: write(state, summary)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:stop, :normal, state}

  defp continue(%{phase: :closed} = state) do
    :gen_tcp.close(state.socket)
    {:stop, :normal, state}
  end

  defp continue(state) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  # Greeting and choosing

  defp greet(state) do
    write(state, "Welcome to AVWE, Azmaveth's Virtual World Engine.")

    case Enum.sort_by(Avwe.worlds(), fn {_id, info} -> info.name end) do
      [] ->
        write(state, "No worlds are running right now. Come back later.")
        %{state | phase: :closed}

      [{id, info}] ->
        enter_world(state, id, info)

      worlds ->
        write(state, "Which world?")
        for {_id, info} <- worlds, do: write(state, "  #{info.name}")
        %{state | phase: :choosing_world}
    end
  end

  defp enter_world(state, id, info) do
    write(state, "You are in #{info.name}." <> if(info.tagline, do: " #{info.tagline}", else: ""))
    offer_bodies(%{state | world: id})
  end

  defp offer_bodies(state) do
    {:ok, bodies} = Avwe.bodies(state.world)
    write(state, "Who will you be?")

    for body <- bodies do
      taken = if body.taken, do: " (being played)", else: ""

      write(
        state,
        "  #{body.name}#{taken}" <> if(body.description, do: " - #{body.description}", else: "")
      )
    end

    write(state, "  watch - watch without a body")
    %{state | phase: :choosing_body}
  end

  defp handle_line(%{phase: :choosing_world} = state, line) do
    worlds = Avwe.worlds()

    case Command.resolve(line, Enum.map(worlds, fn {id, info} -> {to_string(id), info.name} end)) do
      {:ok, id} ->
        {world, info} = Enum.find(worlds, fn {world, _info} -> to_string(world) == id end)
        enter_world(state, world, info)

      _no_match ->
        write(state, "There's no world called \"#{line}\".")
        state
    end
  end

  defp handle_line(%{phase: :choosing_body} = state, line) do
    if String.downcase(line) == "watch" do
      join(state, nil, "You are watching. Nobody can see you.")
    else
      choose_body(state, line)
    end
  end

  defp handle_line(%{phase: :playing} = state, line), do: run(state, Command.parse(line))
  defp handle_line(state, _line), do: state

  defp choose_body(state, line) do
    {:ok, bodies} = Avwe.bodies(state.world)

    case Command.resolve(line, Enum.map(bodies, &{&1.id, &1.name})) do
      {:ok, id} ->
        body = Enum.find(bodies, &(&1.id == id))
        join(state, body, "You are #{body.name}.")

      {:ambiguous, names} ->
        write(state, "Which do you mean: #{Enum.join(names, ", ")}?")
        state

      :none ->
        write(
          state,
          "There's nobody called \"#{line}\" here. Choose someone from the list, or watch."
        )

        state
    end
  end

  defp join(state, body, welcome) do
    case Avwe.connect(state.world, body: body && body.id, controller: :human) do
      {:ok, session} ->
        write(state, welcome)
        state = %{state | session: session, phase: :playing}
        run(state, :look)

      {:error, :body_taken} ->
        write(state, "#{body.name} is already being played. Choose someone else, or watch.")
        state
    end
  end

  # Playing

  defp run(state, :look) do
    {:ok, look} = Session.look(state.session)
    write(state, Prose.look(look))
    state
  end

  defp run(state, {:go, query}) do
    {:ok, look} = Session.look(state.session)
    places = Enum.map(look.places, &{&1.id, &1.name}) ++ here(look)

    case Command.resolve(query, places) do
      {:ok, place} -> act(state, :go, target: place)
      {:ambiguous, names} -> write(state, "Which do you mean: #{Enum.join(names, ", ")}?")
      :none -> write(state, "You don't know a place called \"#{query}\".")
    end

    state
  end

  defp run(state, {:follow, direction}), do: act(state, :follow, params: %{direction: direction})

  defp run(state, {:walk, direction, meters}),
    do: act(state, :walk, params: %{direction: direction, distance_m: meters})

  defp run(state, {:say, volume, text}),
    do: act(state, :say, params: %{text: text, volume: volume})

  defp run(state, {:wait, params}), do: act(state, :wait, params: params)
  defp run(state, :stop), do: act(state, :stop, [])
  defp run(state, {verb, nil}) when verb in [:kindle, :douse], do: act(state, verb, [])

  # A named hearth is one of those within reach: the world answers for the
  # nearest when none is named, never when a name matches nothing.
  defp run(state, {verb, query}) when verb in [:kindle, :douse] do
    {:ok, look} = Session.look(state.session)
    hearths = Enum.map(look[:hearths] || [], &{&1.id, &1.name})

    case Command.resolve(query, hearths) do
      {:ok, hearth} -> act(state, verb, target: hearth)
      {:ambiguous, names} -> write(state, "Which do you mean: #{Enum.join(names, ", ")}?")
      :none -> write(state, "There is no hearth called \"#{query}\" here.")
    end

    state
  end

  defp run(state, :time) do
    write(state, Avwe.now(state.world))
    state
  end

  defp run(state, :help) do
    write(state, @help)
    state
  end

  defp run(state, :quit) do
    write(state, "Goodbye.")
    %{state | phase: :closed}
  end

  defp run(state, :empty), do: state

  defp run(state, {:invalid, message}) do
    write(state, message)
    state
  end

  defp run(state, {:unknown, line}) do
    write(state, "I don't understand \"#{line}\". Type help for a list of commands.")
    state
  end

  defp act(state, verb, opts) do
    case Session.act(state.session, verb, opts) do
      {:ok, _ref} -> :ok
      {:error, :spectator} -> write(state, "You're only watching.")
    end

    state
  end

  defp here(%{here: %{id: id, name: name}}), do: [{id, name}]
  defp here(_look), do: []

  # I/O

  defp write(state, text) do
    lines = text |> String.split("\n") |> Enum.map(&[&1, "\r\n"])
    :gen_tcp.send(state.socket, lines)
  end

  defp clean(data) do
    line = data |> strip_telnet([]) |> String.trim()
    if String.valid?(line), do: line, else: ""
  end

  # Drops telnet protocol sequences (IAC ...) that clients send unasked.
  defp strip_telnet(<<255, 250, rest::binary>>, acc),
    do: rest |> skip_subnegotiation() |> strip_telnet(acc)

  defp strip_telnet(<<255, command, _option, rest::binary>>, acc) when command in 251..254,
    do: strip_telnet(rest, acc)

  defp strip_telnet(<<255, _command, rest::binary>>, acc), do: strip_telnet(rest, acc)
  defp strip_telnet(<<byte, rest::binary>>, acc), do: strip_telnet(rest, [byte | acc])
  defp strip_telnet(<<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp skip_subnegotiation(<<255, 240, rest::binary>>), do: rest
  defp skip_subnegotiation(<<_byte, rest::binary>>), do: skip_subnegotiation(rest)
  defp skip_subnegotiation(<<>>), do: <<>>
end
