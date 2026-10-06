defmodule AvweWeb.Components do
  @moduledoc "The few pieces of page the views share."

  use Phoenix.Component

  attr :flash, :map, required: true

  @doc """
  The notices of the page, as alerts a screen reader announces: what went
  wrong (`:error`) and what it should know (`:info`).
  """
  @spec flash_notices(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_notices(assigns) do
    ~H"""
    <p :if={msg = Phoenix.Flash.get(@flash, :error)} class="notice error" role="alert">{msg}</p>
    <p :if={msg = Phoenix.Flash.get(@flash, :info)} class="notice info" role="status">{msg}</p>
    """
  end
end
