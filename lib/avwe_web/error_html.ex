defmodule AvweWeb.ErrorHTML do
  @moduledoc """
  The pages for errors: the status's own words, as `404.html` is "Not Found".
  """

  use AvweWeb, :html

  @doc "The words for the status a template stands for."
  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end
