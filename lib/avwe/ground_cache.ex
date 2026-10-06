defmodule Avwe.GroundCache do
  @moduledoc """
  Keeps the ground map of each terrain, so it is built once.

  Runtime, not simulation: it holds derived data in `:persistent_term`, keyed
  by the terrain's content, so every session and every world with the same
  terrain shares one map (about 64 KB for the Ember Reach), and the second to
  ask for it pays nothing. Building takes about a second (`Avwe.GroundMap`),
  so concurrent first requests take a lock rather than each doing the work.

  Nothing here is state: it is not snapshotted, journaled or hashed, and a map
  that is lost is built again.
  """

  alias Avwe.{GroundMap, Terrain}

  @doc """
  The ground map of `terrain`, built on the first request for it and kept.
  """
  @spec fetch(Terrain.t()) :: GroundMap.t()
  def fetch(%Terrain{} = terrain) do
    key = key(terrain)

    case :persistent_term.get(key, nil) do
      nil -> build(key, terrain)
      map -> map
    end
  end

  @doc "Whether the ground map of `terrain` is already kept."
  @spec cached?(Terrain.t()) :: boolean()
  def cached?(%Terrain{} = terrain), do: :persistent_term.get(key(terrain), nil) != nil

  defp key(terrain),
    do: {__MODULE__, :crypto.hash(:sha256, :erlang.term_to_binary(terrain, [:deterministic]))}

  # One builder at a time per terrain; whoever waited finds it built.
  defp build(key, terrain) do
    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        nil ->
          map = Terrain.ground_map(terrain)
          :persistent_term.put(key, map)
          map

        map ->
          map
      end
    end)
  end
end
