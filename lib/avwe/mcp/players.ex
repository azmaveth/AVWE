defmodule Avwe.MCP.Players do
  @moduledoc """
  Which MCP player plays which body: one `Avwe.Mind` per player.

  The MCP server's tool handlers live only as long as one request, so the
  Minds are kept here, by player key: the MCP session id for clients that
  have a session (`kind: :session`), or a player token that `join` gave a
  client without one (`kind: :token`; MCP 2026-07-28 has no sessions). A
  Mind ends when:

    * its MCP session is deleted (`Avwe.MCP.Sessions` tells `ended/1`);
    * its MCP session expires in ExMCP's session manager, found by a sweep
      every `:sweep_ms` real milliseconds (default one minute);
    * the player leaves (`leave/1`);
    * nobody calls for its `quit_after` (`Avwe.Mind`), the only end a
      token player has besides leaving, or its world stops.

  A Mind that ends on its own is forgotten, so the player can join again.
  """

  use GenServer

  require Logger

  alias Avwe.Mind

  @sweep_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a Mind for the player `key` (of `kind` `:session` or `:token`)
  playing `body` in `world` (`Avwe.Mind.start/3` with `controller: :mcp`).
  Fails with `:already_joined` when the player plays a body already, or as
  `Avwe.Mind.start/3` does.
  """
  @spec join({:session | :token, String.t()}, atom(), String.t()) ::
          {:ok, pid()} | {:error, term()}
  def join({kind, key}, world, body) when kind in [:session, :token] do
    GenServer.call(__MODULE__, {:join, kind, key, world, body})
  end

  @doc "The player's Mind and its world, or `:error` when it plays nobody."
  @spec mind(String.t() | nil) :: {:ok, pid(), atom()} | :error
  def mind(nil), do: :error

  def mind(key) do
    case GenServer.call(__MODULE__, {:mind, key}) do
      {mind, world} -> {:ok, mind, world}
      nil -> :error
    end
  end

  @doc "Ends the player's Mind, giving the body back to its routine."
  @spec leave(String.t() | nil) :: :ok | {:error, :not_joined}
  def leave(key), do: GenServer.call(__MODULE__, {:leave, key})

  @doc "The MCP session has ended: its Mind, if any, ends too."
  @spec ended(String.t()) :: :ok
  def ended(session) do
    _ = leave(session)
    :ok
  end

  @doc "The players playing a body in `world`, as `%{body => key}`."
  @spec playing(atom()) :: %{String.t() => String.t()}
  def playing(world), do: GenServer.call(__MODULE__, {:playing, world})

  @impl true
  def init(opts) do
    sweep_ms = Keyword.get(opts, :sweep_ms, @sweep_ms)
    Process.send_after(self(), :sweep, sweep_ms)
    {:ok, %{players: %{}, sweep_ms: sweep_ms}}
  end

  @impl true
  def handle_call({:join, kind, key, world, body}, _from, state) do
    if Map.has_key?(state.players, key) do
      {:reply, {:error, :already_joined}, state}
    else
      case Mind.start(world, body, controller: :mcp) do
        {:ok, mind} ->
          monitor = Process.monitor(mind)
          player = %{kind: kind, mind: mind, world: world, body: body, monitor: monitor}
          {:reply, {:ok, mind}, put_in(state.players[key], player)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:mind, session}, _from, state) do
    reply =
      case state.players[session] do
        %{mind: mind, world: world} -> {mind, world}
        nil -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:leave, session}, _from, state) do
    case Map.pop(state.players, session) do
      {nil, _players} ->
        {:reply, {:error, :not_joined}, state}

      {player, players} ->
        close(player)
        {:reply, :ok, %{state | players: players}}
    end
  end

  def handle_call({:playing, world}, _from, state) do
    playing =
      for {session, %{world: ^world, body: body}} <- state.players, into: %{}, do: {body, session}

    {:reply, playing, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _mind, _reason}, state) do
    players = Map.reject(state.players, fn {_session, player} -> player.monitor == monitor end)
    {:noreply, %{state | players: players}}
  end

  # Sessions that expired in ExMCP's session manager end their Minds.
  def handle_info(:sweep, state) do
    {gone, kept} =
      Enum.split_with(state.players, fn {key, player} ->
        player.kind == :session and expired?(key)
      end)

    for {session, player} <- gone do
      Logger.info(
        "MCP session #{String.slice(session, 0, 8)}... expired; releasing #{player.body}"
      )

      close(player)
    end

    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, %{state | players: Map.new(kept)}}
  end

  defp expired?(session) do
    case ExMCP.SessionManager.get_session(session) do
      {:ok, %{status: :active}} -> false
      _terminated_or_gone -> true
    end
  catch
    :exit, _no_session_manager -> false
  end

  defp close(player) do
    Process.demonitor(player.monitor, [:flush])
    Mind.close(player.mind)
  catch
    :exit, _already_gone -> :ok
  end
end
