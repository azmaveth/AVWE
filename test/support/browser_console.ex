defmodule Avwe.Test.BrowserConsole do
  @moduledoc """
  What the page says to the browser's console while a browser test runs,
  collected so that a test can fail on an error: a content security policy
  violation, a script that did not load, an exception nobody caught.

  Playwright gives it every console message and every uncaught page error
  (`PlaywrightEx.JsLogger`); only errors are kept.
  """

  @behaviour PlaywrightEx.JsLogger

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  @impl PlaywrightEx.JsLogger
  def log(:error, text, _message), do: Agent.update(__MODULE__, &[text | &1])
  def log(_level, _text, _message), do: :ok

  @doc "Forgets what was said, as a test begins."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _errors -> [] end)

  @doc "The errors so far, oldest first."
  @spec errors() :: [String.t()]
  def errors, do: __MODULE__ |> Agent.get(& &1) |> Enum.reverse()
end
