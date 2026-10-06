# Used by "mix format"
[
  import_deps: [:phoenix, :phoenix_live_view, :stream_data],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["{mix,.formatter,.credo}.exs", "{config,lib,test}/**/*.{ex,exs,heex}"]
]
