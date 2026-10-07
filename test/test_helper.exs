ExUnit.start(exclude: [:perf, :playwright])

# The browser tests (test/browser) drive Chromium through Playwright, which
# needs Node and a browser: start it only when they are asked for, as in
# `mix test --only playwright`, and point it at the endpoint, which listens on a
# port of the system's choosing. (Their tag is not `:browser`, which the library
# reads as the name of the browser to use.)
if :playwright in ExUnit.configuration()[:include] do
  {:ok, _console} = Avwe.Test.BrowserConsole.start_link([])
  {:ok, _playwright} = PhoenixTest.Playwright.Supervisor.start_link()
  {:ok, {_ip, port}} = AvweWeb.Endpoint.server_info(:http)
  Application.put_env(:phoenix_test, :base_url, "http://127.0.0.1:#{port}")
end
