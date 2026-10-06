defmodule AvweWeb.PlayLive do
  @moduledoc """
  A page that plays one body, at `/play/:world/:body`.

  A page mounts twice, as a plain request and then over its socket. Only the
  second takes the body: it starts an `Avwe.Session` with the page's process
  as its sink, so the body is released when the page closes, as for any
  sink, and the percepts arrive as messages. The first only checks that the
  body is free, so that a held one is refused before anything is drawn. A
  race for a free body is settled by the lease, and the loser is sent back to
  the lobby with the words telnet uses (`Avwe.Prose.body_taken/1`).

  This is the page's shell: who you are, where you are, and what happens, as
  plain lines. The map, the buttons and the command line come after it, and
  so does marking what the routine does while the body is yielded.
  """

  use AvweWeb, :live_view

  alias Avwe.{Prose, Session}

  @max_lines 200

  @impl Phoenix.LiveView
  def mount(%{"world" => world, "body" => body}, _session, socket) do
    with {:ok, world} <- find_world(world),
         {:ok, body} <- find_body(world, body) do
      {:ok, join(socket, world, body)}
    else
      {:error, notice} -> {:ok, leave(socket, notice)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:avwe_percepts, session, percepts}, %{assigns: %{session: session}} = socket) do
    lines = for %{summary: summary} <- percepts, is_binary(summary), do: summary
    {:noreply, update(socket, :lines, &Enum.take(&1 ++ lines, -@max_lines))}
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
        <.link navigate={~p"/"}>Leave</.link>
      </header>
      <.flash_notices flash={@flash} />
      <p :if={@ended} class="notice error" role="alert">
        Your connection to {@world.name} has ended. <.link navigate={~p"/"}>Back to the lobby</.link>
      </p>
      <section :if={@arrival != []} class="arrival" aria-label="Where you are">
        <p :for={line <- @arrival}>{line}</p>
      </section>
      <section aria-label="What happens">
        <ol class="log" aria-live="polite">
          <li :for={line <- @lines}>{line}</li>
        </ol>
      </section>
    </main>
    """
  end

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
    socket = assign(socket, world: world, body: body, page_title: body.name)

    cond do
      connected?(socket) -> take(socket, world, body)
      body.taken -> leave(socket, taken(body))
      true -> arrive(socket, nil, nil, [])
    end
  end

  defp take(socket, world, body) do
    with {:ok, session} <- Avwe.connect(world.id, body: body.id, controller: :human),
         {:ok, look} <- Session.look(session) do
      arrive(socket, session, Process.monitor(session), arrival(look))
    else
      {:error, :body_taken} -> leave(socket, taken(body))
      {:error, _gone} -> leave(socket, "#{world.name} has stopped.")
    end
  end

  # `Avwe.connect/2` makes the page's own process the sink by default.
  defp arrive(socket, session, monitor, arrival) do
    assign(socket, session: session, monitor: monitor, arrival: arrival, lines: [], ended: false)
  end

  defp arrival(look), do: look |> Prose.look() |> String.split("\n", trim: true)

  defp taken(body), do: Prose.body_taken(body.name) <> " Choose someone else."

  defp leave(socket, notice) do
    socket |> put_flash(:error, notice) |> push_navigate(to: ~p"/")
  end
end
