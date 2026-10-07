defmodule AvweWeb.LobbyLive do
  @moduledoc """
  The lobby: the running worlds, and the bodies in each, free or being played.

  A free body is a link to its page (`AvweWeb.PlayLive`). One that somebody
  holds is shown and cannot be chosen, unless a page of this very browser holds
  it: that is the player's own, and may be chosen, which takes it over from that
  page (DESIGN 14, "who is a page"). Each world also has a link to watch it
  (`AvweWeb.WatchLive`), which takes no body. As telnet lists them, only the words
  differ:
  bodies are taken and freed and worlds start and stop without telling anyone,
  so the page looks again every two real seconds while it is open
  (`config :avwe, :lobby_refresh_ms`; `nil` for never, which the tests use, as
  they send the refresh themselves).
  """

  use AvweWeb, :live_view

  alias AvweWeb.{BrowserId, Pages}

  @refresh_ms 2_000

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    if connected?(socket), do: schedule_refresh()
    browser = BrowserId.from(session)
    {:ok, assign(socket, page_title: "Lobby", browser: browser, worlds: worlds(browser))}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, :worlds, worlds(socket.assigns.browser))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main class="page lobby">
      <h1>AVWE</h1>
      <p class="lede">Azmaveth's Virtual World Engine. Choose a world, and someone in it.</p>
      <.flash_notices flash={@flash} />
      <p :if={@worlds == []} class="empty">No worlds are running right now. Come back later.</p>
      <section :for={world <- @worlds} class="world" aria-labelledby={"world-#{world.id}"}>
        <h2 id={"world-#{world.id}"}>{world.name}</h2>
        <p :if={world.tagline} class="tagline">{world.tagline}</p>
        <p :if={world.time} class="time">{world.time}</p>
        <p class="watch">
          <.link navigate={~p"/watch/#{world.id}"}>Watch {world.name}</.link>
          <span class="state">(see everything, and take no part)</span>
        </p>
        <h3>Who will you be?</h3>
        <ul class="bodies">
          <li
            :for={body <- world.bodies}
            class={["body", body.taken && !body.yours && "taken", body.yours && "yours"]}
          >
            <span :if={body.taken and !body.yours} class="name">{body.name}</span>
            <span :if={body.taken and !body.yours} class="state">(being played)</span>
            <.link
              :if={!body.taken or body.yours}
              class="name"
              navigate={~p"/play/#{world.id}/#{body.id}"}
            >
              {body.name}
            </.link>
            <span :if={body.yours} class="state">
              (open on another page of this browser; choosing it here takes it over)
            </span>
            <span :if={body.description} class="description">{body.description}</span>
          </li>
        </ul>
      </section>
    </main>
    """
  end

  defp schedule_refresh do
    case Application.get_env(:avwe, :lobby_refresh_ms, @refresh_ms) do
      nil -> :ok
      ms -> Process.send_after(self(), :refresh, ms)
    end
  end

  # A world that stopped between the two questions is left out. A body is the
  # browser's own when it is taken, and a page of this browser holds it.
  defp worlds(browser) do
    held = Pages.held_by(browser)

    for {id, info} <- Enum.sort_by(Avwe.worlds(), fn {_id, info} -> info.name end),
        {:ok, bodies} <- [Avwe.bodies(id)] do
      bodies = for body <- bodies, do: Map.put(body, :yours, body.taken and {id, body.id} in held)
      %{id: id, name: info.name, tagline: info.tagline, time: time(id), bodies: bodies}
    end
  end

  defp time(world) do
    case Avwe.now(world) do
      time when is_binary(time) -> time
      _stopped -> nil
    end
  end
end
