defmodule AvweWeb.BrowserId do
  @moduledoc """
  Who a page is, as far as the server can tell: the browser it is open in
  (DESIGN 14, "who is a page").

  The first time a browser asks for a page, a random id is put in its session,
  which is its cookie, and it stays as long as the cookie does: until the
  browser is closed. A page's `mount/3` is given the session, so all the pages
  of one browser know the same id, and `AvweWeb.Pages` uses it to tell a page
  that asks for a body its own browser's old page holds from one that is
  somebody else's.

  It is the identity of a browser and not of a person: another browser, another
  device or a cleared cookie is somebody else, and nobody logs in. It is also a
  key, since whoever has it can take the browser's bodies from its pages, so it
  is long and random, and it is never shown to or given to another browser.
  """

  @behaviour Plug

  import Plug.Conn, only: [get_session: 1, put_session: 3]

  @key "browser_id"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case from(get_session(conn)) do
      nil -> put_session(conn, @key, new())
      _id -> conn
    end
  end

  @doc "The id in a session, as a page's `mount/3` is given it, or `nil` when it has none."
  @spec from(map()) :: String.t() | nil
  def from(%{"browser_id" => id}) when is_binary(id) and id != "", do: id
  def from(_session), do: nil

  defp new, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
