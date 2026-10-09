defmodule Avwe.System do
  @moduledoc """
  A rule of the world, applied to a region once per step.

  A system is a pure function of the region and the step. It must not do I/O,
  read the wall clock, or use randomness other than `Avwe.Tick.rng/2`. A system
  that only acts at certain moments checks `Avwe.Tick.crossed?/3` rather than
  counting steps, because steps vary in length.

  A system has a stable **id** (`c:system_id/0`): its rule's id, a slash and its name
  (`"earthlike.heat/step"`). A region lists ids, not modules, and
  `Avwe.SystemTable` says which module runs one, so a module can be moved or
  renamed without breaking a saved world. A system may also be given a
  **period** when it is listed (`{id, every: seconds}`): it then runs only in
  a step that reaches a multiple of that many seconds (`Avwe.Region`).
  """

  @doc """
  The stable id of the system: `"<rule id>/<name>"`. Optional, for systems made
  on the spot (a test's); one that does not give it is known by its module's
  name (`Avwe.SystemTable.id/1`), which a rename changes.
  """
  @callback system_id() :: String.t()

  @callback run(Avwe.Region.t(), Avwe.Tick.t()) :: {Avwe.Region.t(), [Avwe.Event.t()]}

  @doc """
  Sets up state that depends on the region's starting time, such as the light
  level, so it is right before the first step. Optional.
  """
  @callback prepare(Avwe.Region.t()) :: Avwe.Region.t()

  @optional_callbacks prepare: 1, system_id: 0
end
