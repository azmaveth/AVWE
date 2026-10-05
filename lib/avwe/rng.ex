defmodule Avwe.Rng do
  @moduledoc """
  Deterministic random streams.

  Every system gets its own stream for every step in every region, derived from
  `{world_seed, region_id, time, system}`. So a system's randomness never
  depends on what other systems drew, on the order systems run in, or on
  whether the region was stepped live or caught up later. A system that
  draws for each of several entities names the entity too, `{module, id}`,
  so one entity's draws never depend on which others are there.

  Systems get their stream through `Avwe.Tick.rng/2` and must never call
  `:rand` without an explicit state.
  """

  @spec state(integer(), term(), integer(), module() | {module(), term()}) :: :rand.state()
  def state(seed, region_id, time, system) do
    <<a::64, b::64, c::64, _rest::binary>> =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({seed, region_id, time, system}, [:deterministic])
      )

    :rand.seed_s(:exsss, {a, b, c})
  end
end
