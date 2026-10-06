defmodule AvweWeb.LobbyLive do
  @moduledoc """
  The lobby: the running worlds, and the bodies in each, free or being played.

  Each body is shown as telnet lists it, free or "(being played)". Bodies are
  taken and freed and worlds start and stop without
  telling anyone, so the page looks again every two real seconds while it is
  open (`config :avwe, :lobby_refresh_ms`; `nil` for never, which the tests
  use, as they send the refresh themselves).
  """

  use AvweWeb, :live_view

  @refresh_ms 2_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()
    {:ok, assign(socket, page_title: "Lobby", worlds: worlds())}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign(socket, :worlds, worlds())}
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
        <h3>Who will you be?</h3>
        <ul class="bodies">
          <li :for={body <- world.bodies} class={["body", body.taken && "taken"]}>
            <span :if={body.taken} class="name">{body.name}</span>
            <span :if={body.taken} class="state">(being played)</span>
            <span :if={!body.taken} class="name">{body.name}</span>
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

  # A world that stopped between the two questions is left out.
  defp worlds do
    for {id, info} <- Enum.sort_by(Avwe.worlds(), fn {_id, info} -> info.name end),
        {:ok, bodies} <- [Avwe.bodies(id)] do
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
