defmodule AvweWeb.PlayLive do
  @moduledoc """
  A page that plays one body, at `/play/:world/:body`.

  A page mounts twice, as a plain request and then over its socket. Only the
  second takes the body: it starts an `Avwe.Session` with the page's process
  as its sink, so the body is released when the page closes, as for any sink,
  and the percepts and scenes arrive as messages. The first only shows the page
  and says it is joining, and decides nothing about the body, because a browser
  keeps the page it is leaving until the new one begins to arrive, so a body
  that page holds is still held when the request comes. A race for a free body
  is settled by the lease, and the loser (after a short wait for a page that is
  only letting go) is sent back to the lobby with the words telnet uses
  (`Avwe.Prose.body_taken/1`).

  The page has four parts, and each is the same thing the others are:

    * **the map**, a canvas drawn by the `SceneCanvas` hook from the scene the
      session sends (`Avwe.Scene`). The hook draws what it is given and
      reports where a click fell; what a click means is decided here. A click
      on a place goes there, a click on anything else names it, and a click
      outside the circle of sight says it is out of sight;
    * **the log**, the percepts as lines, as telnet shows them, with what the
      routine does while the body is yielded styled apart;
    * **the look and the buttons**: the description of where you are, which is
      the map in words, and what the body can do as buttons (`AvweWeb.Hud`),
      and a banner when the routine has the body;
    * **the command line**, the words telnet takes (`Avwe.Command`).

  A button and a click are a command line: all three go through `run/2`, so
  there is one way into the world and the page has no more power than a
  player typing. Typing, pressing and clicking are the player's presence:
  they touch the session, as telnet's commands do, so the body is kept in
  hand while the player is here and goes back to its routine when they have
  not been for a while. Redrawing the look is not presence (`Session.peek/1`),
  or the page itself would keep the body for ever.
  """

  use AvweWeb, :live_view

  alias Avwe.{Command, Prose, Scene, Session}
  alias AvweWeb.Hud

  @max_lines 200
  @refresh_ms 2_000
  @retry_ms 1_500
  @retry_every_ms 100

  @web_help """
  Lines in grey are what your routine does with you while you stop acting. Any command you type and any button you press keeps you in hand a while longer, and any that acts (go, say, wait, light...) takes you back if the routine had you. Clicking a place on the map goes there.\
  """

  @impl Phoenix.LiveView
  def mount(%{"world" => world, "body" => body}, _session, socket) do
    socket = socket |> stream(:log, []) |> assign(next_line: 1)

    with {:ok, world} <- find_world(world),
         {:ok, body} <- find_body(world, body) do
      {:ok, join(socket, world, body)}
    else
      {:error, notice} -> {:ok, leave(socket, notice)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("command", %{"line" => line}, socket) when is_binary(line) do
    {:noreply, run(socket, Command.parse(line))}
  end

  def handle_event("cell", %{"x" => x, "y" => y}, socket) when is_integer(x) and is_integer(y) do
    {:noreply, click(socket, {x, y})}
  end

  # Anything else is not something the page sends.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:avwe_percepts, session, percepts}, %{assigns: %{session: session}} = socket) do
    {lines, yielded} = Enum.flat_map_reduce(percepts, socket.assigns.yielded, &show/2)
    {:noreply, socket |> assign(:yielded, yielded) |> log(lines) |> redraw()}
  end

  def handle_info({:avwe_scene, session, scene}, %{assigns: %{session: session}} = socket) do
    {:noreply, socket |> put_scene(scene) |> redraw()}
  end

  def handle_info(:refresh, %{assigns: %{session: nil}} = socket), do: {:noreply, socket}

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, redraw(socket)}
  end

  # The session ended: its world stopped, or it went.
  def handle_info(
        {:DOWN, monitor, :process, _session, _reason},
        %{assigns: %{monitor: monitor}} = socket
      ) do
    {:noreply, assign(socket, session: nil, monitor: nil, ended: true)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main class="page play">
      <header>
        <h1>{@body.name}</h1>
        <p class="where">{@world.name}</p>
        <p :if={@hud} class="clock">{@hud.clock}</p>
        <.link navigate={~p"/"}>Leave</.link>
      </header>
      <.flash_notices flash={@flash} />
      <p :if={@ended} class="notice error" role="alert">
        Your connection to {@world.name} has ended. <.link navigate={~p"/"}>Back to the lobby</.link>
      </p>
      <p :if={@session == nil and not @ended} class="notice" role="status">
        Joining {@world.name}...
      </p>
      <p :if={@yielded} class="notice" role="status">
        Your routine has you; act to take yourself back.
      </p>
      <div class="stage">
        <section class="map" aria-label="Map">
          <canvas
            id="map"
            phx-hook="SceneCanvas"
            data-scene={@scene_json}
            role="img"
            aria-label="A map of what you can see. The description below says the same."
          ></canvas>
          <div :if={@scene_json} class="map-tools">
            <button
              id="map-zoom"
              type="button"
              aria-pressed="false"
              phx-click={
                JS.toggle_attribute({"aria-pressed", "true", "false"})
                |> JS.dispatch("map:zoom", to: "#map")
              }
            >
              Wider view
            </button>
            <details :if={@legend != []} class="legend">
              <summary>Legend</summary>
              <ul>
                <li :for={{char, name} <- @legend}><span class="glyph">{char}</span> {name}</li>
              </ul>
            </details>
          </div>
        </section>
        <section :if={@hud} class="hud" aria-label="What you can do">
          <div :for={group <- @hud.groups} class="group">
            <h2>{group.title}</h2>
            <button
              :for={button <- group.buttons}
              type="button"
              phx-click="command"
              phx-value-line={button.line}
            >
              {button.label}
            </button>
          </div>
        </section>
      </div>
      <section id="look" class="look" aria-label="Where you are" aria-live="polite">
        <p :for={line <- @look_lines}>{line}</p>
      </section>
      <section aria-label="What happens">
        <ol id="log" class="log" role="log" phx-update="stream" phx-hook="LogScroll">
          <li :for={{dom_id, line} <- @streams.log} id={dom_id} class={["line", line.kind]}>
            <span :if={line.kind == :routine} class="sr-only">Your routine: </span>
            <span class="text" phx-no-format>{line.text}</span>
          </li>
        </ol>
      </section>
      <form :if={@session} id="command" class="command" phx-submit="command" phx-hook="CommandLine">
        <label for="command-line">Say or do</label>
        <input
          id="command-line"
          name="line"
          type="text"
          autocomplete="off"
          autocapitalize="none"
          spellcheck="false"
          placeholder="look, say hello, help"
        />
        <button type="submit">Do</button>
      </form>
    </main>
    """
  end

  # Taking the body

  defp find_world(param) do
    case Enum.find(Avwe.worlds(), fn {id, _info} -> to_string(id) == param end) do
      {id, info} -> {:ok, %{id: id, name: info.name}}
      nil -> {:error, "That world is not running."}
    end
  end

  defp find_body(world, param) do
    with {:ok, bodies} <- Avwe.bodies(world.id),
         %{} = body <- Enum.find(bodies, &(&1.id == param)) do
      {:ok, body}
    else
      _nobody -> {:error, "There is nobody by that name in #{world.name}."}
    end
  end

  defp join(socket, world, body) do
    socket =
      assign(socket,
        world: world,
        body: body,
        page_title: body.name,
        session: nil,
        monitor: nil,
        ended: false,
        yielded: false,
        hud: nil,
        look_lines: [],
        scene: nil,
        scene_json: nil,
        legend: []
      )

    if connected?(socket), do: take(socket, world, body), else: socket
  end

  # `Avwe.connect/2` makes the page's own process the sink by default.
  defp take(socket, world, body) do
    opts = [body: body.id, controller: :human, scenes: true] ++ idle_after()

    with {:ok, session} <- retrying(fn -> Avwe.connect(world.id, opts) end),
         {:ok, look} <- Session.look(session),
         {:ok, scene} <- Session.scene(session) do
      schedule_refresh()

      socket
      |> assign(session: session, monitor: Process.monitor(session))
      |> log(for line <- lines(look), do: {:reply, line})
      |> show_look(look)
      |> put_scene(scene)
    else
      {:error, :body_taken} -> leave(socket, taken(body))
      {:error, _gone} -> leave(socket, "#{world.name} has stopped.")
    end
  end

  defp taken(body), do: Prose.body_taken(body.name) <> " Choose someone else."

  defp leave(socket, notice) do
    socket |> put_flash(:error, notice) |> push_navigate(to: ~p"/")
  end

  # How long the session waits for a sign of the player before it hands the
  # body to its routine: the session's own default, unless configured (the
  # tests make it short).
  defp idle_after do
    case Application.get_env(:avwe, :play_idle_after_ms) do
      nil -> []
      ms -> [idle_after: ms]
    end
  end

  # A page that is reloaded, or that comes back after its connection dropped,
  # asks for the body its own old page still holds, until that page's process
  # is gone. So a body that is held is waited for a little at the socket before
  # anyone is told it is taken (one that somebody else holds costs the wait and
  # is refused). Only the socket can wait: a browser keeps the old page alive
  # until the new document begins to arrive, so a plain request that waited for
  # the old page to let go would wait for something that cannot happen until
  # it answers. This covers a reload, not a question that is only answered by
  # knowing who a page is (DESIGN 14, question 12). The tests make it short.
  defp retrying(fun), do: retrying(fun, now() + retry_ms())

  defp retrying(fun, deadline) do
    case fun.() do
      {:error, :body_taken} = held ->
        if now() < deadline do
          Process.sleep(@retry_every_ms)
          retrying(fun, deadline)
        else
          held
        end

      other ->
        other
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp retry_ms, do: Application.get_env(:avwe, :play_retry_ms, @retry_ms)

  defp schedule_refresh do
    case Application.get_env(:avwe, :play_refresh_ms, @refresh_ms) do
      nil -> :ok
      ms -> Process.send_after(self(), :refresh, ms)
    end
  end

  # What the player sees of the world

  # The look is the world as the body senses it, in words, and the HUD what
  # it can do. Neither is presence, so both are read with a peek.
  defp redraw(%{assigns: %{session: nil}} = socket), do: socket

  defp redraw(socket) do
    case with_session(socket, &Session.peek/1) do
      {:ok, look} -> show_look(socket, look)
      _gone -> socket
    end
  end

  defp show_look(socket, look) do
    assign(socket, look_lines: lines(%{look | away: []}), hud: Hud.build(look))
  end

  defp lines(look), do: look |> Prose.look() |> String.split("\n", trim: true)

  defp put_scene(socket, nil), do: socket

  defp put_scene(socket, %Scene{} = scene) do
    assign(socket,
      scene: scene,
      scene_json: scene |> Scene.to_map() |> Jason.encode!(),
      legend: legend(scene)
    )
  end

  defp legend(scene) do
    for {_kind, layers} <- scene.legend |> Enum.sort_by(fn {_kind, layers} -> layers.name end),
        do: {layers.glyph.char, layers.name}
  end

  # The log

  defp log(socket, lines) do
    Enum.reduce(lines, socket, fn {kind, text}, socket ->
      n = socket.assigns.next_line
      entry = %{id: "line-#{n}", kind: kind, text: text}
      socket |> assign(:next_line, n + 1) |> stream_insert(:log, entry, limit: -@max_lines)
    end)
  end

  # Percepts are shown in order, each against who held the body when it
  # happened: the hand-over percepts move the `yielded` flag as they pass.
  defp show(percept, yielded) do
    yielded = hand_over(yielded, percept)

    case percept do
      %{summary: summary} when is_binary(summary) ->
        {[{kind(percept, yielded), summary}], yielded}

      _wordless ->
        {[], yielded}
    end
  end

  defp hand_over(_yielded, %{type: :control_released}), do: true
  defp hand_over(_yielded, %{type: :control_taken}), do: false
  defp hand_over(yielded, _percept), do: yielded

  # What is done with the body while the player has yielded it is the
  # routine's: its actions and its fires, whoever asked for them.
  defp kind(%{issuer: issuer}, true) when issuer != nil, do: :routine
  defp kind(_percept, _yielded), do: :percept

  # What the player does

  # A button, a click and a typed line all come here.
  defp run(%{assigns: %{session: nil}} = socket, _command),
    do: reply(socket, "You are no longer in the world.")

  defp run(socket, command) do
    look = if Command.needs_look?(command), do: look(socket)

    case Command.interpret(command, look) do
      {:act, verb, opts} -> act(socket, verb, opts)
      {:error, message} -> present(socket, message)
      :look -> reply(socket, look |> look_of(socket) |> lines() |> Enum.join("\n"))
      :time -> present(socket, Avwe.now(socket.assigns.world.id))
      :help -> present(socket, Command.help() <> "\n" <> @web_help)
      :quit -> push_navigate(socket, to: ~p"/")
      :noop -> socket
    end
  end

  defp look(socket) do
    case with_session(socket, &Session.look/1) do
      {:ok, look} -> look
      _gone -> nil
    end
  end

  defp look_of(nil, socket), do: look(socket)
  defp look_of(look, _socket), do: look

  defp act(socket, verb, opts) do
    case with_session(socket, &Session.act(&1, verb, opts)) do
      {:ok, _ref} -> socket
      _refused -> reply(socket, "That can't be done now.")
    end
  end

  # Asking the time or for help is the player's presence, not an act: the
  # session keeps the body in hand for them.
  defp present(socket, text) do
    with_session(socket, &Session.touch/1)
    reply(socket, text)
  end

  defp reply(socket, text) do
    log(socket, for(line <- String.split(text, "\n"), do: {:reply, line}))
  end

  # A session that has gone since the page last heard of it is no error here:
  # the page is told, and says so.
  defp with_session(socket, fun) do
    fun.(socket.assigns.session)
  catch
    :exit, _gone -> {:error, :gone}
  end

  # A click on the map

  defp click(%{assigns: %{scene: nil}} = socket, _cell), do: socket

  defp click(socket, cell) do
    scene = socket.assigns.scene

    case {thing_at(scene, cell, :place), thing_at(scene, cell), Scene.kind_at(scene, cell)} do
      {%{id: id}, _thing, _kind} -> run(socket, Command.parse("go to #{id}"))
      {nil, %{name: name} = thing, _kind} -> present(socket, "#{named(name, thing)} is there.")
      {nil, nil, nil} -> present(socket, "You can't see that far.")
      {nil, nil, kind} -> present(socket, "You see #{scene.legend[kind].name} there.")
    end
  end

  defp thing_at(scene, cell), do: Enum.find(scene.things, &(&1.cell == cell))

  defp thing_at(scene, cell, kind),
    do: Enum.find(scene.things, &(&1.cell == cell and &1.kind == kind))

  # What a thing is called, to start a sentence: its name, with its first
  # letter a capital and the rest as it is (a place keeps its own capitals).
  defp named(name, thing) when name in [nil, ""], do: String.capitalize(to_string(thing.kind))
  defp named(<<first::utf8, rest::binary>>, _thing), do: String.upcase(<<first::utf8>>) <> rest
end
