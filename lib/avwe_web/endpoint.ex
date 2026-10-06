defmodule AvweWeb.Endpoint do
  @moduledoc """
  The web client's HTTP endpoint, on Bandit: `http://127.0.0.1:4042` in dev.

  It listens on loopback and has no accounts, so anyone who can reach the
  port can take any free body; putting it anywhere else is a decision for
  whoever runs it, with TLS and an identity in front (docs/m2-spec.md, 3.4).
  Three things keep a page that is not ours from using it:

    * `AvweWeb.LoopbackHost` answers 403 to a request for any name but its
      own, so a page at another name that resolves to 127.0.0.1 cannot read
      ours;
    * a socket opens only from the origin its page came from
      (`check_origin: :conn`, see config/config.exs), so neither another site
      nor another service on this machine can open one;
    * a LiveView joins only with the signed token in the page it rendered.

  The session holds nothing but the CSRF secret.
  """

  use Phoenix.Endpoint, otp_app: :avwe

  @session_options [
    store: :cookie,
    key: "_avwe_key",
    signing_salt: "Hp3sYx9d",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug AvweWeb.LoopbackHost

  plug Plug.Static,
    at: "/",
    from: :avwe,
    gzip: false,
    only: AvweWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Head
  plug Plug.Session, @session_options
  plug AvweWeb.Router
end
