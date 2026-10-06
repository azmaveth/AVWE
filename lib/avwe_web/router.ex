defmodule AvweWeb.Router do
  @moduledoc """
  The pages: the lobby.

  Browser pages get the secure headers and a content security policy that
  lets scripts and styles come from the page's own origin only: the bundle is
  one file, so nothing is inline.
  """

  use AvweWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AvweWeb.Layouts, :root}
    plug :protect_from_forgery

    # Everything comes from the page's own origin: the one script and the one
    # stylesheet are bundled files, so nothing is inline and nothing is
    # `unsafe`. No plugins, no framing, no other base or form target. It is a
    # literal because Sobelow reads it there; a test reads its directives.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    }
  end

  scope "/", AvweWeb do
    pipe_through :browser

    live "/", LobbyLive
  end
end
