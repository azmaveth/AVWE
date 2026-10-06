defmodule AvweWeb do
  @moduledoc """
  The web client: pages that let a person play a body through the same
  `Avwe.Session` that telnet and MCP use. It has no way into the world that
  they do not have.

  `use AvweWeb, :live_view` (or `:html`, `:router`) gives a module what its
  kind needs, so that they all start alike.
  """

  @doc "The folders of `priv/static` the endpoint serves."
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets)

  @doc false
  @spec router() :: Macro.t()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Phoenix.Controller
      import Phoenix.LiveView.Router
      import Plug.Conn
    end
  end

  @doc false
  @spec live_view() :: Macro.t()
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @doc false
  @spec html() :: Macro.t()
  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AvweWeb.Endpoint,
        router: AvweWeb.Router,
        statics: AvweWeb.static_paths()

      import AvweWeb.Components
      import Phoenix.HTML

      alias Phoenix.LiveView.JS
    end
  end

  @doc false
  defmacro __using__(which) when is_atom(which), do: apply(__MODULE__, which, [])
end
