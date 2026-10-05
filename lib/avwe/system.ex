defmodule Avwe.System do
  @moduledoc """
  A rule of the world, applied to a region once per step.

  A system is a pure function of the region and the step. It must not do I/O,
  read the wall clock, or use randomness other than `Avwe.Tick.rng/2`. A system
  that only acts at certain moments checks `Avwe.Tick.crossed?/3` rather than
  counting steps, because steps vary in length.
  """

  @callback run(Avwe.Region.t(), Avwe.Tick.t()) :: {Avwe.Region.t(), [Avwe.Event.t()]}

  @doc """
  Sets up state that depends on the region's starting time, such as the light
  level, so it is right before the first step. Optional.
  """
  @callback prepare(Avwe.Region.t()) :: Avwe.Region.t()

  @optional_callbacks prepare: 1
end
