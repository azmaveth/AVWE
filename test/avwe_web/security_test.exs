defmodule AvweWeb.SecurityTest do
  use Avwe.Test.WebCase, async: false

  describe "a page" do
    test "carries the secure headers, and a policy that lets scripts and styles come from itself only",
         %{conn: conn} do
      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ "AVWE"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
      assert get_resp_header(conn, "x-permitted-cross-domain-policies") == ["none"]

      assert [policy] = get_resp_header(conn, "content-security-policy")

      directives =
        policy |> String.split("; ") |> Map.new(&List.to_tuple(String.split(&1, " ", parts: 2)))

      assert directives["default-src"] == "'self'"
      assert directives["script-src"] == "'self'"
      assert directives["style-src"] == "'self'"
      assert directives["connect-src"] == "'self'"
      assert directives["object-src"] == "'none'"
      assert directives["frame-ancestors"] == "'none'"
      assert directives["base-uri"] == "'self'"
      refute policy =~ "unsafe"
    end

    test "has no inline script or style for the policy to refuse", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      scripts = Regex.scan(~r/<script\b[^>]*>/, html)
      assert scripts != []
      assert Enum.all?(scripts, fn [tag] -> tag =~ ~r/\ssrc="\/assets\/app\.js"/ end)
      refute html =~ ~r/<style\b/
      refute html =~ ~r/\sstyle=/
      assert html =~ ~s(href="/assets/app.css")
    end

    test "sets a session cookie that a script cannot read and another site cannot send",
         %{conn: conn} do
      conn = get(conn, ~p"/")

      assert [cookie] = get_resp_header(conn, "set-cookie")
      assert cookie =~ "_avwe_key="
      assert cookie =~ ~r/HttpOnly/i
      assert cookie =~ ~r/SameSite=Lax/i
    end

    test "that is not there is a 404 in the status's own words", %{conn: conn} do
      assert conn |> get("/nowhere") |> response(404) == "Not Found"
    end
  end

  describe "the name a request is made to" do
    test "may be any loopback name", %{conn: conn} do
      for host <- ["localhost", "127.0.0.1", "[::1]"] do
        assert conn |> Map.put(:host, host) |> get(~p"/") |> response(200) =~ "AVWE", host
      end
    end

    test "may not be another, which a page that rebinds its name to 127.0.0.1 would send",
         %{conn: conn} do
      for host <- [
            "evil.example",
            "localhost.evil.example",
            "127.0.0.1.evil.example",
            "www.example.com"
          ] do
        conn = conn |> Map.put(:host, host) |> get(~p"/")

        assert response(conn, 403) == "This server answers only to its own name.", host
        assert halted?(conn), host
      end
    end

    test "may be one the endpoint is configured to answer to", %{conn: conn} do
      config = Application.fetch_env!(:avwe, AvweWeb.Endpoint)

      Application.put_env(
        :avwe,
        AvweWeb.Endpoint,
        Keyword.put(config, :allowed_hosts, ["avwe.example"])
      )

      on_exit(fn -> Application.put_env(:avwe, AvweWeb.Endpoint, config) end)

      assert conn |> Map.put(:host, "avwe.example") |> get(~p"/") |> response(200) =~ "AVWE"
      assert conn |> Map.put(:host, "localhost") |> get(~p"/") |> response(403)
    end
  end

  defp halted?(conn), do: conn.halted
end
