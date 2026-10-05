defmodule Avwe.Tick do
  @moduledoc """
  The context for one step of a region.

  A step covers world time after `time`, up to and including `time + dt`.
  Systems must use `dt` and never assume a step is one minute, because history
  mode takes larger steps.
  """

  alias Avwe.Rng

  @enforce_keys [:step, :time, :dt, :seed, :region]
  defstruct [:step, :time, :dt, :seed, :region]

  @type t :: %__MODULE__{
          step: non_neg_integer(),
          time: Avwe.Calendar.time(),
          dt: pos_integer(),
          seed: integer(),
          region: term()
        }

  @doc "World time at the end of the step."
  @spec end_time(t()) :: Avwe.Calendar.time()
  def end_time(%__MODULE__{time: time, dt: dt}), do: time + dt

  @doc "The random state for `system` in this step. See `Avwe.Rng`."
  @spec rng(t(), module()) :: :rand.state()
  def rng(%__MODULE__{} = tick, system), do: Rng.state(tick.seed, tick.region, tick.time, system)

  @doc """
  True when the step reaches a moment that repeats every `interval` seconds,
  shifted by `offset`. A moment exactly at the start of the step belongs to the
  previous step, so nothing is counted twice.

      # Does this step reach 06:00?
      Tick.crossed?(tick, Calendar.day(), 6 * Calendar.hour())
  """
  @spec crossed?(t(), pos_integer(), integer()) :: boolean()
  def crossed?(%__MODULE__{time: time, dt: dt}, interval, offset \\ 0) do
    Integer.floor_div(time + dt - offset, interval) >
      Integer.floor_div(time - offset, interval)
  end

  @doc """
  The latest moment at or before the end of the step that repeats every
  `interval` seconds, shifted by `offset`. Use it with `crossed?/3` to stamp an
  event with the exact time it happened.
  """
  @spec last_occurrence(t(), pos_integer(), integer()) :: Avwe.Calendar.time()
  def last_occurrence(%__MODULE__{} = tick, interval, offset \\ 0) do
    Integer.floor_div(end_time(tick) - offset, interval) * interval + offset
  end
end
