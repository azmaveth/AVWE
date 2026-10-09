defmodule Avwe.Application do
  @moduledoc false

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    :ok = Avwe.Ruleset.register_known()

    children =
      [
        {Registry, keys: :unique, name: Avwe.Registry},
        {Registry, keys: :duplicate, name: Avwe.PubSub},
        {DynamicSupervisor, name: Avwe.Worlds, strategy: :one_for_one},
        {DynamicSupervisor, name: Avwe.Sessions, strategy: :one_for_one},
        {DynamicSupervisor, name: Avwe.Minds, strategy: :one_for_one},
        Avwe.MCP.Players,
        {Task, &autostart/0},
        {Phoenix.PubSub, name: AvweWeb.PubSub},
        {Registry, keys: :duplicate, name: AvweWeb.Pages},
        AvweWeb.Endpoint
      ] ++ telnet() ++ mcp()

    Supervisor.start_link(children, strategy: :one_for_one, name: Avwe.Supervisor)
  end

  # Starts the worlds listed in `config :avwe, :autostart`, and says in words
  # why one cannot start (public for the test that reads what it says).
  @doc false
  @spec autostart() :: :ok
  def autostart do
    for {id, opts} <- Application.get_env(:avwe, :autostart, []) do
      case Avwe.start_world(id, opts) do
        {:ok, _pid} ->
          Logger.info("Started world #{inspect(id)}")
          Avwe.warm_ground(id)

        {:error, reason} ->
          Logger.warning(
            "Couldn't start world #{inspect(id)}: #{Avwe.Definition.explain(reason)}"
          )
      end
    end

    :ok
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
