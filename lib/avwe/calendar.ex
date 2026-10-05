defmodule Avwe.Calendar do
  @moduledoc """
  World time.

  World time is an integer count of seconds since the start of 0 AR. A year has
  365 days of 24 hours. Months and seasons can come later; nothing in the Ember
  Reach needs them yet.
  """

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @year 365 * @day

  @type time :: integer()

  @type parts :: %{
          year: integer(),
          day: pos_integer(),
          hour: non_neg_integer(),
          minute: non_neg_integer(),
          second: non_neg_integer()
        }

  @doc "Seconds in a minute."
  @spec minute() :: pos_integer()
  def minute, do: @minute

  @doc "Seconds in an hour."
  @spec hour() :: pos_integer()
  def hour, do: @hour

  @doc "Seconds in a day."
  @spec day() :: pos_integer()
  def day, do: @day

  @doc "Seconds in a year."
  @spec year() :: pos_integer()
  def year, do: @year

  @doc """
  Builds a world time from a year in AR and an optional `:day` (1-based),
  `:hour` and `:minute`.

      iex> Avwe.Calendar.at(813, day: 220, hour: 4) |> Avwe.Calendar.format()
      "813 AR, day 220, 04:00"
  """
  @spec at(integer(), keyword()) :: time()
  def at(year, opts \\ []) do
    year * @year +
      (Keyword.get(opts, :day, 1) - 1) * @day +
      Keyword.get(opts, :hour, 0) * @hour +
      Keyword.get(opts, :minute, 0) * @minute
  end

  @doc "Splits a world time into its year, day of year (1-based), hour, minute and second."
  @spec describe(time()) :: parts()
  def describe(time) do
    year = Integer.floor_div(time, @year)
    in_year = Integer.mod(time, @year)
    in_day = Integer.mod(in_year, @day)

    %{
      year: year,
      day: div(in_year, @day) + 1,
      hour: div(in_day, @hour),
      minute: div(rem(in_day, @hour), @minute),
      second: rem(in_day, @minute)
    }
  end

  @doc "Seconds since midnight."
  @spec time_of_day(time()) :: non_neg_integer()
  def time_of_day(time), do: Integer.mod(time, @day)

  @doc "Formats a world time for people."
  @spec format(time()) :: String.t()
  def format(time) do
    %{year: year, day: day, hour: hour, minute: minute} = describe(time)
    "#{year} AR, day #{day}, #{pad(hour)}:#{pad(minute)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
