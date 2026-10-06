defmodule Avwe.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Avwe.Registry},
        {Registry, keys: :duplicate, name: Avwe.PubSub},
        {DynamicSupervisor, name: Avwe.Worlds, strategy: :one_for_one},
        {DynamicSupervisor, name: Avwe.Sessions, strategy: :one_for_one},
        {DynamicSupervisor, name: Avwe.Minds, strategy: :one_for_one},
        Avwe.MCP.Players,
        {Task, &autostart/0}
      ] ++ telnet() ++ mcp()

    Supervisor.start_link(children, strategy: :one_for_one, name: Avwe.Supervisor)
  end

  # Starts the worlds listed in `config :avwe, :autostart`.
  defp autostart do
    for {id, opts} <- Application.get_env(:avwe, :autostart, []) do
      case Avwe.start_world(id, opts) do
        {:ok, _pid} ->
          Logger.info("Started world #{inspect(id)}")

        {:error, reason} ->
          Logger.warning("Couldn't start world #{inspect(id)}: #{inspect(reason)}")
      end
    end
  end

  defp mcp do
    case Application.get_env(:avwe, :mcp) do
      nil -> []
      opts -> [{Avwe.MCP, opts}]
    end
  end

  defp telnet do
    case Application.get_env(:avwe, :telnet) do
      nil -> []
      opts -> [{Avwe.Telnet, Keyword.put_new(opts, :name, Avwe.Telnet)}]
    end
  end
end
