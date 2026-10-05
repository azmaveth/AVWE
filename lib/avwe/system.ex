defmodule Avwe.System do
  @moduledoc """
  A rule of the world, applied to a region once per step.

  A system is a pure function of the region and the step. It must not do I/O,
  read the wall clock, or use randomness other than `Avwe.Tick.rng/2`. A system
  that only acts at certain moments checks `Avwe.Tick.crossed?/3` rather than
  counting steps, because steps vary in length.
  """

  @callback run(Avwe.Region.t(), Avwe.Tick.t()) :: {Avwe.Region.t(), [Avwe.Event.t()]}
end
