defmodule Avwe.MCP.Endpoint do
  @moduledoc """
  The HTTP front of the MCP server: the endpoint is `/mcp`
  (`http://127.0.0.1:4041/mcp` in dev), served by `Arbor.MCP.HttpPlug`.

  Around it, four things of AVWE's own:

    * a GET on the endpoint answers 405 with `allow: POST, DELETE`, as the
      streamable HTTP transport asks of a server that offers no stream to
      listen on (clients then just POST);
    * any other path is 404, so there is one endpoint, not one per path;
    * the server's instructions are written for each request, so they tell
      the world's clock as it is configured (`Avwe.MCP.instructions/1`);
    * a DELETE that ends an MCP session also ends its player's Mind
      (`Avwe.MCP.Players.ended/1`), once the response says that it did.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbor.MCP.HttpPlug
  alias Avwe.MCP.Players

  @impl Plug
  def init(opts) do
    {world, opts} = Keyword.pop(opts, :world, :ember_reach)
    %{world: world, http: HttpPlug.init(opts)}
  end

  @impl Plug
  def call(%Plug.Conn{path_info: ["mcp"], method: "GET"} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> put_resp_content_type("text/plain")
    |> send_resp(405, "This MCP endpoint takes POST and DELETE; it offers no stream to GET.")
    |> halt()
  end

  def call(%Plug.Conn{path_info: ["mcp"]} = conn, %{world: world, http: http}) do
    conn
    |> end_session_on_delete()
    |> HttpPlug.call(Map.put(http, :instructions, Avwe.MCP.instructions(world)))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found. The MCP endpoint is /mcp.")
    |> halt()
  end

  # ArborMCP ends the session itself and says so with a 204; only then is the
  # session's player let go. A DELETE for a session that is not there is
  # answered otherwise, and ends nobody.
  defp end_session_on_delete(%Plug.Conn{method: "DELETE"} = conn) do
    case session_id(conn) do
      nil ->
        conn

      session ->
        register_before_send(conn, fn
          %Plug.Conn{status: 204} = sent ->
            Players.ended(session)
            sent

          sent ->
            sent
        end)
    end
  end

  defp end_session_on_delete(conn), do: conn

  defp session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id | _] -> id
      [] -> nil
    end
  end
end
