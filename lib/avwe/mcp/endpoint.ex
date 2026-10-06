defmodule Avwe.MCP.Endpoint do
  @moduledoc """
  The HTTP front of the MCP server: the endpoint is `/mcp`
  (`http://127.0.0.1:4041/mcp` in dev), served by `ExMCP.HttpPlug`.

  Around it, three things of AVWE's own:

    * a GET on the endpoint answers 405 with `allow: POST, DELETE`, as the
      streamable HTTP transport asks of a server that offers no stream to
      listen on (clients then just POST);
    * any other path is 404, so there is one endpoint, not one per path;
    * the server's instructions are written for each request, so they tell
      the world's clock as it is configured (`Avwe.MCP.instructions/1`).
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts) do
    {world, opts} = Keyword.pop(opts, :world, :ember_reach)
    %{world: world, http: ExMCP.HttpPlug.init(opts)}
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
    ExMCP.HttpPlug.call(conn, Map.put(http, :instructions, Avwe.MCP.instructions(world)))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found. The MCP endpoint is /mcp.")
    |> halt()
  end
end
