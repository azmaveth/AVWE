defmodule Avwe.MixProject do
  use Mix.Project

  def project do
    [
      app: :avwe,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      hex: hex()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Avwe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # `mix lint` is what the pre-commit hook runs (about a second warm) and what
  # CI's lint job runs, step by step. Dialyzer, Sobelow and the audit are
  # slower or need the network, so they are separate (see CLAUDE.md).
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild avwe"],
      "assets.deploy": ["esbuild avwe --minify"],
      lint: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --warnings-as-errors",
        "credo --strict"
      ]
    ]
  end

  # The PLTs live in priv/plts (git-ignored) so CI can cache them. The
  # flags go beyond the defaults and find nothing today; `:missing_return`
  # (specs narrower than the code) was left off, it flags integer-versus-
  # float arithmetic mostly.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :unknown]
    ]
  end

  # Advisories `mix hex.audit` (run in CI) is told to accept, each with why.
  # Hex warns when an entry matches nothing in mix.lock any more, which is
  # the prompt to delete it, as it will be once cowlib has a release past
  # 2.20.0.
  #
  # cowlib 2.20.0, the newest release when this was written:
  #   * EEF-CVE-2026-43966, response splitting in the structured-field
  #     string encoder. Only cow_http_hd's Variants, Variant-Key and
  #     WT-* header builders reach it; nothing here (AVWE, Plug, Cowboy's
  #     HTTP/1.1 path, ExMCP) calls them.
  #   * EEF-CVE-2026-43969, header injection in cow_cookie:cookie/1, which
  #     builds a request's Cookie header for a client. AVWE only serves, and
  #     Gun, the client that would call it, is not a dependency.
  defp hex do
    [ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969"]]
  end

  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:ex_mcp, "~> 1.5"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false}
    ]
  end
end
