defmodule Avwe.Calendar do
  @moduledoc """
  World time.

  World time is an integer count of seconds since the start of year 0. A minute
  is 60 seconds and an hour 60 minutes in every world (`docs/engine-spec.md`,
  decision 8). What a **calendar** says is the rest: how many hours make a day,
  how many days a year, and what the years are counted in (`epoch`, "AR" in the
  Ember Reach). A calendar is a value, `%Avwe.Calendar{}`, which a region keeps
  (`Avwe.Region`) and hands its systems in the tick (`Avwe.Tick`), so a world
  with a 20-hour day is the same kind of thing as one with a 24-hour day.

  `earth/0` is the default, and the functions that take no calendar are the
  Earth's: 365 days of 24 hours counted in "AR". Months and seasons can come
  later; nothing in the Ember Reach needs them yet.
  """

  @minute 60
  @hour 60 * @minute

  defstruct hours_per_day: 24, days_per_year: 365, epoch: "AR"

  @typedoc "A calendar: the length of its day and year, and what the years are counted in."
  @type t :: %__MODULE__{
          hours_per_day: pos_integer(),
          days_per_year: pos_integer(),
          epoch: String.t()
        }

  @type time :: integer()

  @type parts :: %{
          year: integer(),
          day: pos_integer(),
          hour: non_neg_integer(),
          minute: non_neg_integer(),
          second: non_neg_integer()
        }

  @doc "The Earth's calendar: 365 days of 24 hours, counted in \"AR\"."
  @spec earth() :: t()
  def earth, do: %__MODULE__{}

  @doc "Seconds in a minute."
  @spec minute() :: pos_integer()
  def minute, do: @minute

  @doc "Seconds in an hour."
  @spec hour() :: pos_integer()
  def hour, do: @hour

  @doc "Seconds in a day of the Earth's calendar."
  @spec day() :: pos_integer()
  def day, do: day(earth())

  @doc "Seconds in a day of `calendar`."
  @spec day(t()) :: pos_integer()
  def day(%__MODULE__{hours_per_day: hours}), do: hours * @hour

  @doc "Seconds in a year of the Earth's calendar."
  @spec year() :: pos_integer()
  def year, do: year(earth())

  @doc "Seconds in a year of `calendar`."
  @spec year(t()) :: pos_integer()
  def year(%__MODULE__{days_per_year: days} = calendar), do: days * day(calendar)

  @doc """
  Builds a world time from a year in AR and an optional `:day` (1-based),
  `:hour` and `:minute`.

      iex> Avwe.Calendar.at(813, day: 220, hour: 4) |> Avwe.Calendar.format()
      "813 AR, day 220, 04:00"
  """
  @spec at(integer(), keyword()) :: time()
  def at(year, opts \\ []), do: at(earth(), year, opts)

  @doc "`at/2` in `calendar`."
  @spec at(t(), integer(), keyword()) :: time()
  def at(%__MODULE__{} = calendar, year, opts) do
    year * year(calendar) +
      (Keyword.get(opts, :day, 1) - 1) * day(calendar) +
      Keyword.get(opts, :hour, 0) * @hour +
      Keyword.get(opts, :minute, 0) * @minute
  end

  @doc "Splits a world time into its year, day of year (1-based), hour, minute and second."
  @spec describe(time()) :: parts()
  def describe(time), do: describe(earth(), time)

  @doc "`describe/1` in `calendar`."
  @spec describe(t(), time()) :: parts()
  def describe(%__MODULE__{} = calendar, time) do
    year = Integer.floor_div(time, year(calendar))
    in_year = Integer.mod(time, year(calendar))
    in_day = Integer.mod(in_year, day(calendar))

    %{
      year: year,
      day: div(in_year, day(calendar)) + 1,
      hour: div(in_day, @hour),
      minute: div(rem(in_day, @hour), @minute),
      second: rem(in_day, @minute)
    }
  end

  @doc """
  The first moment strictly after `time` that repeats every `interval` seconds,
  shifted by `offset`.

      iex> Avwe.Calendar.at(813, hour: 4)
      ...> |> Avwe.Calendar.next(Avwe.Calendar.day(), 6 * Avwe.Calendar.hour())
      ...> |> Avwe.Calendar.format()
      "813 AR, day 1, 06:00"
  """
  @spec next(time(), pos_integer(), integer()) :: time()
  def next(time, interval, offset \\ 0) do
    Integer.floor_div(time - offset, interval) * interval + offset + interval
  end

  @doc "Seconds since midnight."
  @spec time_of_day(time()) :: non_neg_integer()
  def time_of_day(time), do: time_of_day(earth(), time)

  @doc "Seconds since midnight in `calendar`."
  @spec time_of_day(t(), time()) :: non_neg_integer()
  def time_of_day(%__MODULE__{} = calendar, time), do: Integer.mod(time, day(calendar))

  @doc "Formats a world time for people."
  @spec format(time()) :: String.t()
  def format(time), do: format(earth(), time)

  @doc "`format/1` in `calendar`: the year with its epoch, the day of the year, the time of day."
  @spec format(t(), time()) :: String.t()
  def format(%__MODULE__{epoch: epoch} = calendar, time) do
    %{year: year, day: day, hour: hour, minute: minute} = describe(calendar, time)
    "#{year} #{epoch}, day #{day}, #{pad(hour)}:#{pad(minute)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
