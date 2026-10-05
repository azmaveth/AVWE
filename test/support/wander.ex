defmodule Avwe.Test.Wander do
  @moduledoc """
  A test-only system that uses randomness: every entity with a position takes
  one random step (or stays put) each step. Used to check determinism.
  """

  @behaviour Avwe.System

  alias Avwe.{Region, Tick}

  @impl Avwe.System
  def run(region, tick) do
    {region, _rng} =
      region
      |> Region.with_components([:position])
      |> Enum.reduce({region, Tick.rng(tick, __MODULE__)}, &wander/2)

    {region, []}
  end

  defp wander(id, {region, rng}) do
    {dx, rng} = :rand.uniform_s(3, rng)
    {dy, rng} = :rand.uniform_s(3, rng)
    {x, y} = Region.get(region, id, :position)
    {Region.put_component(region, id, :position, {x + dx - 2, y + dy - 2}), rng}
  end
end
