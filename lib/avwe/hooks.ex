defmodule Avwe.Hooks do
  @moduledoc """
  What a layer above the simulation asks of a region when it comes back from
  disk. A world is started with a list of hook modules
  (`Avwe.RegionServer`'s `:hooks`); the simulation calls each one that defines
  a callback, and knows nothing of what it does.

  `context` is `%{world: id, dir: store folder, definition: hash or nil}`.
  """

  alias Avwe.{Input, Region}

  @type context :: %{world: term(), dir: Path.t() | nil, definition: String.t() | nil}

  @doc """
  The inputs to submit, and journal, when a region has been started: state that
  the layer finds out of date because the world was stopped (a hold that nobody
  keeps any more, for the agent layer). Each is accepted as if
  it had been submitted from outside, so replay gives the same. `region` is the
  region as it is, with the inputs already waiting.
  """
  @callback on_resume(Region.t(), context()) :: [Input.t()]

  @doc """
  Called when a saved region is resumed under a given one that may differ from
  it in what the layer configures. It reports what it ignores, in the log; the
  saved state wins.
  """
  @callback on_reconfigure(saved :: Region.t(), given :: Region.t(), context()) :: :ok

  @optional_callbacks on_resume: 2, on_reconfigure: 3
end
