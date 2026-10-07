defmodule AvweWeb.Pages do
  @moduledoc """
  The pages that hold a body, and whose browsers they are open in (DESIGN 14,
  "who is a page").

  A page that has taken a body registers here, under `{world, body}`, with the
  id of its browser (`AvweWeb.BrowserId`), and is gone from here when it lets
  go or when the page is. The registry is the web client's own: the lease
  (`Avwe.Session`) is the world's exclusivity check and knows no browsers, and
  telnet and MCP never come here.

  Two things are asked of it. A page that finds its body held asks the pages of
  its own browser that hold it to let go (`ask_to_let_go/3`): it is the same
  player come back, and the latest page wins, since the server cannot tell an
  old page whose connection has dropped from one that is still open. And the
  lobby asks which bodies a browser's pages hold (`held_by/1`), to offer them.
  A page whose browser has no id (one that keeps no cookies) is neither asked
  nor offered.
  """

  @doc "Records that the calling page holds `body` of `world`, for `browser`."
  @spec register(atom(), String.t(), String.t() | nil) :: :ok
  def register(_world, _body, nil), do: :ok

  def register(world, body, browser) do
    {:ok, _owner} = Registry.register(__MODULE__, {world, body}, browser)
    :ok
  end

  @doc "Records that the calling page no longer holds `body` of `world`."
  @spec release(atom(), String.t()) :: :ok
  def release(world, body), do: Registry.unregister(__MODULE__, {world, body})

  @doc """
  Tells the pages of `browser`, other than the caller, that hold `body` of
  `world` to let go: each gets `:let_go`.
  """
  @spec ask_to_let_go(atom(), String.t(), String.t() | nil) :: :ok
  def ask_to_let_go(_world, _body, nil), do: :ok

  def ask_to_let_go(world, body, browser) do
    me = self()

    Registry.dispatch(__MODULE__, {world, body}, fn pages ->
      for {page, ^browser} <- pages, page != me, do: send(page, :let_go)
    end)
  end

  @doc "The `{world, body}` that pages of `browser` hold, in order."
  @spec held_by(String.t() | nil) :: [{atom(), String.t()}]
  def held_by(nil), do: []

  def held_by(browser) do
    __MODULE__
    |> Registry.select([{{:"$1", :_, :"$2"}, [{:==, :"$2", browser}], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  end
end
