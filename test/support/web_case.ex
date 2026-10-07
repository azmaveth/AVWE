defmodule Avwe.Test.WebCase do
  @moduledoc """
  The setup for tests of the web client through its endpoint: a conn from a
  loopback name, as a browser's is (the endpoint answers no other), and the
  helpers of `Phoenix.ConnTest` and `Phoenix.LiveViewTest`. A test that needs
  a world starts its own.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AvweWeb.Endpoint,
        router: AvweWeb.Router,
        statics: AvweWeb.static_paths()

      import Avwe.Test.Fixtures
      import Avwe.Test.WebCase, only: [in_browser: 2, session_of: 2]
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn, only: [get_resp_header: 2]

      @endpoint AvweWeb.Endpoint
    end
  end

  setup do
    {:ok, conn: Map.put(Phoenix.ConnTest.build_conn(), :host, "localhost")}
  end

  @doc """
  The conn as a request from the browser `id`: its session has that browser's
  id, as the cookie of one browser's pages does (`AvweWeb.BrowserId`).
  """
  @spec in_browser(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def in_browser(conn, id), do: Phoenix.ConnTest.init_test_session(conn, %{"browser_id" => id})

  @doc "The session that holds `body` in `world`: whatever page or client took it."
  @spec session_of(atom(), String.t()) :: pid()
  def session_of(world, body) do
    [{session, _lease}] = Registry.lookup(Avwe.Registry, {:lease, world, body})
    session
  end
end
