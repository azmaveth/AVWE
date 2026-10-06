defmodule Avwe.MCP.Players do
  @moduledoc """
  Which MCP player plays which body: one `Avwe.Mind` per player.

  The MCP server's tool handlers live only as long as one request, so the
  Minds are kept here, by player key. Keys come in two kinds that never
  meet: `{:session, id}`, the MCP session of a client that has one, and
  `{:token, token}`, a player token that `join` gave a client without one
  (MCP 2026-07-28 has no sessions). A token can never name a session's
  player, nor a session id a token's. A Mind ends when:

    * its MCP session is deleted (`Avwe.MCP.Sessions` tells `ended/1`);
    * its MCP session expires in ExMCP's session manager, found by a sweep
      every `:sweep_ms` real milliseconds (default one minute);
    * the player leaves (`leave/1`);
    * nobody calls for its `quit_after`, 15 real minutes by
      default here (the `:quit_after` option, in ms), so an abandoned
      player frees its body; this is the only end a token player has
      besides leaving. Or its world stops.

  A Mind that ends on its own is forgotten, so the player can join again.

  `join/3` starts the Mind in the caller's process and only then registers
  it here, so a slow start never holds up other players' calls; a Mind
  that cannot be registered (the player joined meanwhile) is closed again.
  """

  use GenServer

  require Logger

  alias Avwe.Mind

  @sweep_ms 60_000
  @quit_after 15 * 60_000

  @type key :: {:session, String.t()} | {:token, String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a Mind for the player `key` playing `body` in `world`
  (`Avwe.Mind.start/3` with `controller: :mcp` and this server's
  `quit_after`). Fails with `:already_joined` when the player plays a body
  already, or as `Avwe.Mind.start/3` does.
  """
  @spec join(key(), atom(), String.t()) :: {:ok, pid()} | {:error, term()}
  def join({kind, id} = key, world, body) when kind in [:session, :token] and is_binary(id) do
    with {:ok, quit_after} <- GenServer.call(__MODULE__, {:free, key}),
         {:ok, mind} <- Mind.start(world, body, controller: :mcp, quit_after: quit_after) do
      register(key, mind, world, body)
    end
  end

  defp register(key, mind, world, body) do
    case GenServer.call(__MODULE__, {:register, key, mind, world, body}) do
      :ok ->
        {:ok, mind}

      {:error, reason} ->
        Mind.close(mind)
        {:error, reason}
    end
  catch
    :exit, reason ->
      Mind.close(mind)
      exit(reason)
  end

  @doc "The player's Mind and its world, or `:error` when it plays nobody."
  @spec mind(key() | nil) :: {:ok, pid(), atom()} | :error
  def mind(nil), do: :error

  def mind(key) do
    case GenServer.call(__MODULE__, {:mind, key}) do
      {mind, world} -> {:ok, mind, world}
      nil -> :error
    end
  end

  @doc "Ends the player's Mind, giving the body back to its routine."
  @spec leave(key() | nil) :: :ok | {:error, :not_joined}
  def leave(nil), do: {:error, :not_joined}
  def leave(key), do: GenServer.call(__MODULE__, {:leave, key})

  @doc "The MCP session `id` has ended: its Mind, if any, ends too."
  @spec ended(String.t()) :: :ok
  def ended(session) do
    _ = leave({:session, session})
    :ok
  end

  @doc "Real milliseconds without a call before a player's Mind ends."
  @spec quit_after() :: pos_integer()
  def quit_after, do: GenServer.call(__MODULE__, :quit_after)

  @doc "The players playing a body in `world`, as `%{body => key}`."
  @spec playing(atom()) :: %{String.t() => key()}
  def playing(world), do: GenServer.call(__MODULE__, {:playing, world})

  @impl true
  def init(opts) do
    sweep_ms = Keyword.get(opts, :sweep_ms, @sweep_ms)
    Process.send_after(self(), :sweep, sweep_ms)

    {:ok,
     %{players: %{}, sweep_ms: sweep_ms, quit_after: Keyword.get(opts, :quit_after, @quit_after)}}
  end

  @impl true
  def handle_call({:free, key}, _from, state) do
    if Map.has_key?(state.players, key),
      do: {:reply, {:error, :already_joined}, state},
      else: {:reply, {:ok, state.quit_after}, state}
  end

  def handle_call(:quit_after, _from, state), do: {:reply, state.quit_after, state}

  def handle_call({:register, key, mind, world, body}, _from, state) do
    if Map.has_key?(state.players, key) do
      {:reply, {:error, :already_joined}, state}
    else
      monitor = Process.monitor(mind)
      player = %{mind: mind, world: world, body: body, monitor: monitor}
      {:reply, :ok, put_in(state.players[key], player)}
    end
  end

  def handle_call({:mind, key}, _from, state) do
    reply =
      case state.players[key] do
        %{mind: mind, world: world} -> {mind, world}
        nil -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:leave, key}, _from, state) do
    case Map.pop(state.players, key) do
      {nil, _players} ->
        {:reply, {:error, :not_joined}, state}

      {player, players} ->
        close(player)
        {:reply, :ok, %{state | players: players}}
    end
  end

  def handle_call({:playing, world}, _from, state) do
    playing =
      for {key, %{world: ^world, body: body}} <- state.players, into: %{}, do: {body, key}

    {:reply, playing, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _mind, _reason}, state) do
    players = Map.reject(state.players, fn {_key, player} -> player.monitor == monitor end)
    {:noreply, %{state | players: players}}
  end

  # Sessions that expired in ExMCP's session manager end their Minds.
  def handle_info(:sweep, state) do
    {gone, kept} =
      Enum.split_with(state.players, fn
        {{:session, session}, _player} -> expired?(session)
        {{:token, _token}, _player} -> false
      end)

    for {{:session, session}, player} <- gone do
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
  end
end
