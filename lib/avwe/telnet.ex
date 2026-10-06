defmodule Avwe.Telnet do
  @moduledoc """
  The telnet front door. Listens on a TCP port and starts an
  `Avwe.Telnet.Connection` for each player.

  Enable it with `config :avwe, :telnet, port: 4040`, or start it yourself
  with `port: 0` to get a free port (see `port/1`). `idle_after`, real
  milliseconds, is passed to each player's session (`Avwe.connect/2`): how
  long a player may stop typing before the body goes back to its routine.
  """

  use GenServer

  alias Avwe.Telnet.Connection

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "The port the server is listening on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @impl GenServer
  def init(opts) do
    options = [:binary, packet: :line, active: false, reuseaddr: true]

    case :gen_tcp.listen(Keyword.get(opts, :port, 4040), options) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        {:ok, connections} = DynamicSupervisor.start_link(strategy: :one_for_one)
        session_opts = Keyword.take(opts, [:idle_after])
        spawn_link(fn -> accept(listen, connections, session_opts) end)
        Logger.info("Telnet listening on port #{port}")
        {:ok, %{listen: listen, port: port, connections: connections}}

      {:error, reason} ->
        {:stop, {:listen, reason}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(listen, connections, session_opts) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          DynamicSupervisor.start_child(connections, {Connection, {socket, session_opts}})

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :socket_ready)
        accept(listen, connections, session_opts)

      {:error, :closed} ->
        :ok
    end
  end
end
