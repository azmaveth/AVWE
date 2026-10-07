defmodule Avwe.GroundCache do
  @moduledoc """
  Keeps the ground of each terrain, so it is built once: the ground map
  (`fetch/1`), which a body's scene reads, and the world ground (`world/1`),
  which a spectator's page is given.

  Runtime, not simulation: it holds derived data in `:persistent_term`, keyed
  by the terrain's content, so every session and every world with the same
  terrain shares one of each (about 64 KB for the Ember Reach's map), and the
  second to ask for one pays nothing. Building the map takes about a second
  (`Avwe.GroundMap`), so concurrent first requests take a lock rather than each
  doing the work. The world ground is built from the map.

  Nothing here is state: it is not snapshotted, journaled or hashed, and
  anything that is lost is built again.
  """

  alias Avwe.{GroundMap, Terrain, WorldGround}

  @doc """
  The ground map of `terrain`, built on the first request for it and kept.
  """
  @spec fetch(Terrain.t()) :: GroundMap.t()
  def fetch(%Terrain{} = terrain),
    do: kept(key(:map, terrain), fn -> Terrain.ground_map(terrain) end)

  @doc "Whether the ground map of `terrain` is already kept."
  @spec cached?(Terrain.t()) :: boolean()
  def cached?(%Terrain{} = terrain), do: :persistent_term.get(key(:map, terrain), nil) != nil

  @doc """
  The world ground of `terrain` (`Avwe.WorldGround`), built on the first
  request for it and kept. It builds the ground map first if that is not kept.
  """
  @spec world(Terrain.t()) :: WorldGround.t()
  def world(%Terrain{} = terrain),
    do: kept(key(:world, terrain), fn -> WorldGround.build(terrain, fetch(terrain)) end)

  @doc "Whether the world ground of `terrain` is already kept."
  @spec world_cached?(Terrain.t()) :: boolean()
  def world_cached?(%Terrain{} = terrain),
    do: :persistent_term.get(key(:world, terrain), nil) != nil

  defp key(what, terrain),
    do:
      {__MODULE__, what, :crypto.hash(:sha256, :erlang.term_to_binary(terrain, [:deterministic]))}

  # One builder at a time per key; whoever waited finds it built.
  defp kept(key, build) do
    case :persistent_term.get(key, nil) do
      nil -> locked(key, build)
      value -> value
    end
  end

  defp locked(key, build) do
    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        nil ->
          value = build.()
          :persistent_term.put(key, value)
          value

        value ->
          value
      end
    end)
  end
end
