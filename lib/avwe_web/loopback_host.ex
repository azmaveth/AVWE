defmodule AvweWeb.LoopbackHost do
  @moduledoc """
  Answers 403 to a request whose `Host` is not a name the endpoint is meant
  to be reached by: `localhost`, `127.0.0.1` and `[::1]`, or the
  `:allowed_hosts` in the endpoint's configuration.

  The endpoint listens on loopback only, but a page at another name that
  resolves to 127.0.0.1 (DNS rebinding) would still reach it, with that name
  as its `Host`. Refusing every name but ours keeps such a page from reading
  ours. (The MCP server does the same: `Avwe.MCP`.)

  This runs for HTTP requests, which is where a page is read. A socket is
  protected by its origin (`AvweWeb.Endpoint`).
  """

  @behaviour Plug

  import Plug.Conn

  @loopback ~w(localhost 127.0.0.1 [::1])

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if conn.host in allowed_hosts() do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "This server answers only to its own name.")
      |> halt()
    end
  end

  defp allowed_hosts do
    :avwe
    |> Application.get_env(AvweWeb.Endpoint, [])
    |> Keyword.get(:allowed_hosts, @loopback)
  end
end
