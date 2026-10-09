defmodule Avwe.System do
  @moduledoc """
  A rule of the world, applied to a region once per step.

  A system is a pure function of the region and the step. It must not do I/O,
  read the wall clock, or use randomness other than `Avwe.Tick.rng/2`. A system
  that only acts at certain moments checks `Avwe.Tick.crossed?/3` rather than
  counting steps, because steps vary in length.

  A system has a stable **id** (`c:system_id/0`): its rule's id, a slash and its name
  (`"station.power/step"`). A region lists ids, not modules, and
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

  @doc """
  What is wrong with the options a system is listed with, as the words that follow
  "with" (`"every: 0, which is not a whole number of seconds above 0"`), or
  `[]`. A system has one option, `:every`; `also` names more keys a caller reads
  itself (the ruleset reads `:runs_after` and `:runs_before`).
  """
  @spec option_problems(term(), [atom()]) :: [String.t()]
  def option_problems(options, also \\ [])

  def option_problems(options, also) when is_list(options) do
    if Keyword.keyword?(options) do
      for {key, value} <- options, problem <- option_problem(key, value, also), do: problem
    else
      ["options that are not a keyword list"]
    end
  end

  def option_problems(_other, _also), do: ["options that are not a keyword list"]

  defp option_problem(:every, every, _also) when is_integer(every) and every > 0, do: []

  defp option_problem(:every, other, _also),
    do: ["every: #{inspect(other)}, which is not a whole number of seconds above 0"]

  defp option_problem(key, _value, also) do
    if key in also do
      []
    else
      has = Enum.map_join([:every | also], ", ", &inspect/1)
      ["the option #{inspect(key)}, which a system does not have (it has #{has})"]
    end
  end
end
