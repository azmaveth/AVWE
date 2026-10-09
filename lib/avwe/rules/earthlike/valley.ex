defmodule Avwe.Rules.Earthlike.Valley do
  @moduledoc """
  The ground of a river valley (`Avwe.Terrain`): a channel, its reaches, silt
  and clay. It has no system; the terrain is made when the world is built and
  the rules that need it (the river, the heat) read it.
  """

  @behaviour Avwe.Rule

  @impl Avwe.Rule
  def id, do: "earthlike.valley"

  @impl Avwe.Rule
  def version, do: "1.0"

  @impl Avwe.Rule
  def owns, do: [:terrain]

  @impl Avwe.Rule
  def provides, do: [:terrain]
end
