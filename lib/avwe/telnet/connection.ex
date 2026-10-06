defmodule Avwe.Telnet.Connection do
  @moduledoc """
  One telnet player.

  Greets them, has them choose a world if more than one is running, then a
  body (or to watch). The first look after joining begins with what the
  body did while nobody held it ("While you were away:"). After that it turns their commands into intents and
  their percepts into lines of text. Everything goes through an
  `Avwe.Session`, like any other controller. A player who stops typing
  yields the body to its routine (the session's idle rule, `:idle_after` in
  the options): while it is yielded, the lines for what is done with the
  body (its actions, and the fires it lights or puts out) are prefixed with
  `- `, so a reading player can tell them from their own. The prefix
  follows who holds the body, not whose intent a line reports: the
  connection keeps a `yielded` flag from the hand-over percepts it
  receives (`:control_released` sets it, `:control_taken` clears it), so a
  player who takes over a journey the routine began reads its remaining
  lines, and their own stop, unmarked. Any command that acts takes the body
  back; `look`, `time` and `help` re-arm the idle timer (`time` and `help`
  through `Avwe.Session.touch/1`) but do not retake.
  """

  use GenServer, restart: :temporary

  alias Avwe.{Command, Prose, Session}

  @routine_prefix "- "

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
    quit              leave
  Lines starting with "- " are what your routine does with you while you stop acting; any command you type keeps you in hand a while longer, and any command that acts (go, say, wait, light...) takes you back if the routine had you.\
  """

  @spec start_link({:gen_tcp.socket(), keyword()}) :: GenServer.on_start()
  def start_link({socket, opts}), do: GenServer.start_link(__MODULE__, {socket, opts})

  @impl GenServer
  def init({socket, opts}) do
    {:ok,
     %{
       socket: socket,
       phase: :starting,
       world: nil,
       session: nil,
       session_opts: opts,
       yielded: false
     }}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    state |> greet() |> continue()
  end

  def handle_info({:tcp, _socket, data}, state) do
    state |> handle_line(clean(data)) |> continue()
  end

  def handle_info({:avwe_percepts, _session, percepts}, state) do
    {:noreply, Enum.reduce(percepts, state, &show/2)}
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
    opts = [body: body && body.id, controller: :human] ++ state.session_opts

    case Avwe.connect(state.world, opts) do
      {:ok, session} ->
        write(state, welcome)
        state = %{state | session: session, phase: :playing}
        run(state, :look)

      {:error, :body_taken} ->
        write(state, Prose.body_taken(body.name) <> " Choose someone else, or watch.")
        state
    end
  end

  # Playing

  # What a command means is `Avwe.Command`'s to say; this only does it.
  defp run(state, command) do
    look = if Command.needs_look?(command), do: look(state)

    case Command.interpret(command, look) do
      {:act, verb, opts} -> act(state, verb, opts)
      {:error, message} -> reply(state, message)
      :look -> reply(state, Prose.look(look(state)))
      :time -> present(state, Avwe.now(state.world))
      :help -> present(state, @help)
      :quit -> reply(%{state | phase: :closed}, "Goodbye.")
      :noop -> state
    end
  end

  defp look(state) do
    {:ok, look} = Session.look(state.session)
    look
  end

  # Asking the time or for help is the player's presence, not an act: the
  # session keeps the body in hand for them.
  defp present(state, text) do
    :ok = Session.touch(state.session)
    reply(state, text)
  end

  defp reply(state, text) do
    write(state, text)
    state
  end

  defp act(state, verb, opts) do
    case Session.act(state.session, verb, opts) do
      {:ok, _ref} -> :ok
      {:error, :spectator} -> write(state, "You're only watching.")
    end

    state
  end

  # I/O

  # Percepts are shown in order, each against who held the body when it
  # happened: the hand-over percepts move the `yielded` flag as they pass.
  defp show(percept, state) do
    state = hand_over(state, percept)
    if is_binary(percept.summary), do: write(state, line(percept, state))
    state
  end

  defp hand_over(state, %{type: :control_released}), do: %{state | yielded: true}
  defp hand_over(state, %{type: :control_taken}), do: %{state | yielded: false}
  defp hand_over(state, _percept), do: state

  # What is done with the body while the player has yielded it carries the
  # mark: its actions and its fires, whoever asked for them.
  defp line(%{issuer: issuer, summary: summary}, %{yielded: true}) when issuer != nil,
    do: @routine_prefix <> summary

  defp line(%{summary: summary}, _state), do: summary

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
