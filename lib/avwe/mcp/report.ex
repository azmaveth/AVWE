defmodule Avwe.MCP.Report do
  @moduledoc """
  What the MCP tools say: `Avwe.Mind` reports and looks as text for a
  model to read, and as JSON-ready data for `structuredContent`. Pure.

  A report reads as a status line, then the percepts, one per line, each
  with its world time: `05:19 You set off toward Ember Reach.` (with the
  day when it was not today). What the body's routine did with it while
  the program had let it go is marked `(your routine)`.
  """

  alias Avwe.{Calendar, Prose}

  @doc "A Mind report as text."
  @spec text(map(), integer()) :: String.t()
  def text(report, now) do
    [status_line(report, now) | lines(report.percepts, now)] |> Enum.join("\n")
  end

  @doc "The percepts with a summary, one line each."
  @spec lines([Avwe.Percept.t()], integer()) :: [String.t()]
  def lines(percepts, now) do
    for %{summary: summary} = percept <- percepts, is_binary(summary) do
      "#{Prose.stamp(percept.time, now)} #{routine(percept)}#{summary}"
    end
  end

  defp routine(%{issuer: :autopilot}), do: "(your routine) "
  defp routine(_percept), do: ""

  defp status_line(report, now) do
    [
      status(report.status),
      "It is #{Calendar.format(now)}.",
      doing(report.action),
      planned(report.plan),
      dropped(report.dropped)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp status(:done), do: "Done."

  defp status(:failed),
    do: "Failed: the step did not succeed and the rest of the plan was dropped."

  defp status(:interrupted),
    do: "Interrupted: something needs your attention. Your action goes on."

  defp status(:still_going), do: "Still going."
  defp status(:idle), do: "Nothing under way."

  defp doing(nil), do: nil
  defp doing(action), do: "Under way: #{describe(action)}."

  defp planned([]), do: nil

  defp planned(plan),
    do: "Planned after it: #{Enum.map_join(plan, ", ", &describe/1)}."

  defp dropped(0), do: nil
  defp dropped(n), do: "(#{n} older percepts were dropped.)"

  defp describe(%{verb: verb, target: nil}), do: to_string(verb)
  defp describe(%{verb: verb, target: target}), do: "#{verb} #{target}"
  defp describe({verb, opts}), do: describe(%{verb: verb, target: opts[:target]})

  @doc "A Mind report as JSON-ready data."
  @spec data(map(), integer()) :: map()
  def data(report, now) do
    %{
      status: report.status,
      time: Calendar.format(now),
      action: report.action,
      plan: Enum.map(report.plan, &step/1),
      dropped: report.dropped,
      percepts: Enum.map(report.percepts, &percept(&1, now))
    }
  end

  defp step({verb, opts}),
    do: %{verb: verb, target: opts[:target], params: jsonable(Keyword.get(opts, :params, %{}))}

  defp percept(percept, now) do
    percept
    |> Map.take([:kind, :type, :summary, :outcome, :reason, :issuer, :salience, :source, :data])
    |> Map.put(:time, Prose.stamp(percept.time, now))
    |> Map.put(:ref, percept.intent)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> jsonable()
  end

  @doc "A look as JSON-ready data, with its time formatted."
  @spec look(map()) :: map()
  def look(look) do
    look
    |> Map.drop([:away])
    |> Map.put(:time, Calendar.format(look.time))
    |> jsonable()
  end

  @doc "Makes a term encodable as JSON: tuples become lists."
  @spec jsonable(term()) :: term()
  def jsonable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> jsonable()
  def jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, jsonable(v)} end)
  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(other), do: other
end
