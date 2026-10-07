defmodule AvweWeb.WatchLive do
  @moduledoc """
  A page that watches a world, at `/watch/:world`: the whole valley and
  everything in it, with the river, the heat and the smoke drawn over it.

  Nobody holds anything here. The page opens a spectator session with scenes
  (`Avwe.Session`, the page's process its sink), which sees everything and can
  act on nothing, so any number of pages may watch the same world, and the
  question of who a page is (`AvweWeb.BrowserId`) does not arise. A page mounts
  twice, as a plain request and then over its socket; only the second opens a
  session.

  What the page is given is two things. The ground (`Avwe.WorldGround`) never
  changes, so it comes once, in an attribute of its own, as soon as the session
  has built it (the first page for a terrain waits a second for it); the scene
  (`Avwe.WorldScene`) is sent with each step that changes something, in another,
  so that LiveView sends only the one that changed. The `WorldCanvas` hook
  draws them. It holds the zoom, the pan and which overlays are on, which the
  server never hears of: what a click means is decided here (`pick/3`), as it is
  on the play page, and the page can do no more than a watcher can.

  The log is what the telnet watcher is told (the session's percepts), as lines,
  and a name is canon, so both are text, escaped by the templates.
  """

  use AvweWeb, :live_view

  alias Avwe.{Calendar, Repr, Session, WorldGround, WorldScene}

  @max_lines 200

  # The overlays a viewer may switch, with how each is labelled and whether it
  # is on to begin with. The hook starts with the same (assets/js/world.js).
  @overlays [{"water", "River", true}, {"heat", "Heat", false}, {"smoke", "Smoke", true}]

  # What a click can pick: how far it may miss, in cells, and the order in which
  # the things that share a cell are told.
  @reach 4
  @rank %{body: 0, hearth_burning: 1, hearth: 2, place: 3}

  @impl Phoenix.LiveView
  def mount(%{"world" => world}, _session, socket) do
    socket = socket |> stream(:log, []) |> assign(next_line: 1)

    case find_world(world) do
      {:ok, world} -> {:ok, join(socket, world)}
      {:error, notice} -> {:ok, leave(socket, notice)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cell", %{"x" => x, "y" => y, "r" => r}, socket)
      when is_integer(x) and is_integer(y) and is_integer(r) do
    {:noreply, pick(socket, {x, y}, r |> max(0) |> min(@reach))}
  end

  # Anything else is not something the page sends.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:ground, {:ok, {:ok, %WorldGround{} = ground}}, socket) do
    {:noreply, put_ground(socket, ground)}
  end

  # A world with no terrain has no ground to draw; one that is gone is told of
  # by the session's end.
  def handle_async(:ground, {:ok, {:ok, nil}}, socket) do
    {:noreply, assign(socket, no_ground: true)}
  end

  def handle_async(:ground, _gone, socket), do: {:noreply, socket}

  # What the page's session sends is matched to it, as the play page's is: a
  # message from any other would be a bug, and no other can arrive.
  @impl Phoenix.LiveView
  def handle_info(
        {:avwe_scene, session, %WorldScene{} = scene},
        %{assigns: %{session: session}} = socket
      ) do
    {:noreply, put_scene(socket, scene)}
  end

  def handle_info({:avwe_percepts, session, percepts}, %{assigns: %{session: session}} = socket) do
    lines = for %{summary: summary} <- percepts, is_binary(summary), do: summary
    {:noreply, log(socket, lines)}
  end

  # The session ended: its world stopped.
  def handle_info(
        {:DOWN, monitor, :process, _session, _reason},
        %{assigns: %{monitor: monitor}} = socket
      ) do
    {:noreply, assign(socket, session: nil, monitor: nil, ended: true)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main class="page watch">
      <header>
        <h1>{@world.name}</h1>
        <p class="where">Watching</p>
        <p :if={@clock} class="clock">{@clock}</p>
        <.link navigate={~p"/"}>Leave</.link>
      </header>
      <.flash_notices flash={@flash} />
      <p :if={@ended} class="notice error" role="alert">
        {@world.name} has stopped. <.link navigate={~p"/"}>Back to the lobby</.link>
      </p>
      <p :if={@session == nil and not @ended} class="notice" role="status">
        Joining {@world.name}...
      </p>
      <p :if={@session && @ground_json == nil && not @no_ground} class="notice" role="status">
        Drawing the valley...
      </p>
      <p :if={@no_ground} class="notice" role="status">
        {@world.name} has no map to draw.
      </p>
      <div class="stage">
        <section class="map" aria-label="Map">
          <canvas
            id="world"
            phx-hook="WorldCanvas"
            data-ground={@ground_json}
            data-scene={@scene_json}
            role="img"
            aria-label="A map of the whole valley, with the river, the heat and the smoke. The log below says what happens."
          ></canvas>
          <div :if={@scene_json && @ground_json} class="map-tools">
            <div class="tools" role="group" aria-label="Overlays">
              <button
                :for={{name, label, on} <- overlays()}
                id={"overlay-#{name}"}
                type="button"
                aria-pressed={to_string(on)}
                phx-click={
                  JS.toggle_attribute({"aria-pressed", "true", "false"})
                  |> JS.dispatch("map:overlay", to: "#world", detail: %{overlay: name})
                }
              >
                {label}
              </button>
            </div>
            <div class="tools" role="group" aria-label="Zoom">
              <button
                id="zoom-out"
                type="button"
                phx-click={JS.dispatch("map:zoom", to: "#world", detail: %{step: -1})}
              >
                Zoom out
              </button>
              <button
                id="zoom-in"
                type="button"
                phx-click={JS.dispatch("map:zoom", to: "#world", detail: %{step: 1})}
              >
                Zoom in
              </button>
              <button id="zoom-fit" type="button" phx-click={JS.dispatch("map:fit", to: "#world")}>
                Whole valley
              </button>
            </div>
            <details :if={@legend != []} class="legend">
              <summary>Legend</summary>
              <ul>
                <li :for={{char, name} <- @legend}><span class="glyph">{char}</span> {name}</li>
              </ul>
            </details>
          </div>
        </section>
        <section :if={@scene} class="readout" aria-label="What you have picked">
          <h2>Picked</h2>
          <p id="picked" aria-live="polite">
            {@picked || "Click a person, a hearth or a place."}
          </p>
          <.heat_ramp :if={@scene.overlays.heat} ramp={Repr.overlay(:heat).ramp} />
        </section>
      </div>
      <section aria-label="What happens">
        <ol id="log" class="log" role="log" phx-update="stream" phx-hook="LogScroll">
          <li :for={{dom_id, line} <- @streams.log} id={dom_id} class="line percept">
            <span class="text" phx-no-format>{line.text}</span>
          </li>
        </ol>
      </section>
    </main>
    """
  end

  # The heat's ramp, from cold to hot, as a gradient with its degrees: the
  # key to the colours. An SVG, since the policy allows no inline style.
  attr :ramp, :list, required: true

  defp heat_ramp(assigns) do
    assigns = assign(assigns, low: hd(assigns.ramp).at, high: List.last(assigns.ramp).at)

    ~H"""
    <figure class="heat-ramp">
      <svg viewBox="0 0 200 26" role="img" aria-label={"Ground temperature, #{@low} to #{@high} °C"}>
        <defs>
          <linearGradient id="heat-gradient" x1="0" x2="1" y1="0" y2="0">
            <stop
              :for={stop <- @ramp}
              offset={(stop.at - @low) / (@high - @low)}
              stop-color={stop.color}
            />
          </linearGradient>
        </defs>
        <rect x="0" y="0" width="200" height="12" fill="url(#heat-gradient)" />
        <text x="0" y="24" font-size="9" text-anchor="start">{@low} °C</text>
        <text x="200" y="24" font-size="9" text-anchor="end">{@high} °C</text>
      </svg>
    </figure>
    """
  end

  defp overlays, do: @overlays

  # Joining

  defp join(socket, world) do
    socket =
      assign(socket,
        world: world,
        page_title: "Watching #{world.name}",
        session: nil,
        monitor: nil,
        ended: false,
        no_ground: false,
        scene: nil,
        scene_json: nil,
        ground: nil,
        ground_json: nil,
        clock: nil,
        legend: [],
        picked: nil
      )

    if connected?(socket), do: watch(socket, world), else: socket
  end

  # `Avwe.connect/2` makes the page's own process the sink by default. The scene
  # is quick (a snapshot and some arithmetic); the ground, which the first page
  # for a terrain waits a second for, is asked for beside it.
  defp watch(socket, world) do
    with {:ok, session} <- Avwe.connect(world.id, scenes: true),
         {:ok, scene} <- Session.scene(session) do
      socket
      |> assign(session: session, monitor: Process.monitor(session))
      |> put_scene(scene)
      |> start_async(:ground, fn -> Session.ground(session) end)
    else
      {:error, _gone} -> leave(socket, "#{world.name} has stopped.")
    end
  end

  defp find_world(param) do
    case Enum.find(Avwe.worlds(), fn {id, _info} -> to_string(id) == param end) do
      {id, info} -> {:ok, %{id: id, name: info.name}}
      nil -> {:error, "That world is not running."}
    end
  end

  defp leave(socket, notice) do
    socket |> put_flash(:error, notice) |> push_navigate(to: ~p"/")
  end

  # What the page shows

  defp put_ground(socket, %WorldGround{} = ground) do
    socket
    |> assign(ground: ground, ground_json: ground |> WorldGround.to_map() |> Jason.encode!())
    |> put_legend()
  end

  defp put_scene(socket, %WorldScene{} = scene) do
    socket
    |> assign(
      scene: scene,
      scene_json: scene |> WorldScene.to_map() |> Jason.encode!(),
      clock: Calendar.format(scene.time)
    )
    |> put_legend()
  end

  # The kinds of the ground and of the things, once each, by name.
  defp put_legend(socket) do
    ground = if socket.assigns.ground, do: socket.assigns.ground.legend, else: %{}
    things = if socket.assigns.scene, do: socket.assigns.scene.legend, else: %{}

    legend =
      ground
      |> Map.merge(things)
      |> Enum.map(fn {_kind, layers} -> {layers.glyph.char, layers.name} end)
      |> Enum.sort_by(fn {_char, name} -> name end)

    assign(socket, legend: legend)
  end

  # The log

  defp log(socket, lines) do
    Enum.reduce(lines, socket, fn text, socket ->
      n = socket.assigns.next_line
      entry = %{id: "line-#{n}", text: text}
      socket |> assign(:next_line, n + 1) |> stream_insert(:log, entry, limit: -@max_lines)
    end)
  end

  # A click on the map

  # Everything at the nearest cell that has anything within reach: a town has a
  # person, a hearth and a place on one cell, and the watcher is told all three.
  defp pick(socket, {x, y}, reach) do
    scene = socket.assigns.scene

    near =
      for %{cell: {tx, ty}} = thing <- scene.things,
          distance = max(abs(tx - x), abs(ty - y)),
          distance <= reach,
          do: {distance, {tx, ty}, thing}

    picked =
      case Enum.min_by(near, fn {distance, cell, _thing} -> {distance, cell} end, fn -> nil end) do
        nil -> "Nothing there."
        {_distance, cell, _thing} -> describe(for({_d, ^cell, thing} <- near, do: thing), scene)
      end

    assign(socket, picked: picked)
  end

  # What things are, in words: each its name, what sort of thing it is, and for a
  # body who holds it. The names are the world's own.
  defp describe(things, scene) do
    things
    |> Enum.sort_by(&{Map.get(@rank, &1.kind, 4), &1.id})
    |> Enum.map_join("; ", fn thing ->
      "#{thing.name} (#{scene.legend[thing.kind].name})#{held(thing)}"
    end)
    |> Kernel.<>(".")
  end

  defp held(%{kind: :body, holder: nil}), do: ", on its routine"
  defp held(%{kind: :body, holder: holder}), do: ", held by #{holder}"
  defp held(_thing), do: ""
end
