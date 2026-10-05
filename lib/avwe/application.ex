defmodule Avwe.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Avwe.Registry},
      {Registry, keys: :duplicate, name: Avwe.PubSub},
      {DynamicSupervisor, name: Avwe.Worlds, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Avwe.Supervisor)
  end
end
