defmodule Avwe.MCP.Report do
  @moduledoc """
  What the MCP tools say: `Avwe.Mind` reports and looks as text for a
  model to read, and as JSON-ready data for `structuredContent`. Pure.

  A report reads as a status line, then the percepts, one per line, each
  with its world time: `05:19 You set off toward Ember Reach.` (with the
  day when it was not today). What the body's routine did with it while
  the program had let it go is marked `(your routine)`.

  The status line names things as a player would: places and hearths by
  name, not id (from a look taken with the report, or the name the plan
  gave), a wait with the time it ends, and a long plan as its next three
  steps "and 5 more". After `:yielded` it says that the routine has the
  body and the plan is over. Steps a plan dropped unsubmitted (`abandoned`)
  are named: the rest of a failed plan, what a yielded plan still had, or
  what was left of an earlier plan that a new act replaced. A step the
  Mind could not submit (`problem`) is explained.
  """

  alias Avwe.{Calendar, Prose}

  @shown_steps 3

  @doc """
  A Mind report as text. `look`, a look taken with it, names the places
  and hearths the report's ids stand for, and tells when a wait ends.
  """
  @spec text(map(), integer(), map() | nil) :: String.t()
  def text(report, now, look \\ nil) do
    [status_line(report, now, context(look, now)) | lines(report.percepts, now)]
    |> Enum.join("\n")
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

  defp status_line(%{status: :yielded} = report, now, context) do
    [
      "Yielded: your routine took the body back while you were away from the keyboard, " <>
        "and your plan is over.",
      "It is #{Calendar.format(now)}.",
      report.action &&
        "Your routine has the body, in the middle of: #{doing(report.action, context)}.",
      "Act again to take the body back.",
      abandoned(:yielded, report, context),
      dropped(report.dropped)
    ]
    |> join()
  end

  defp status_line(report, now, context) do
    [
      status(report.status),
      problem(Map.get(report, :problem)),
      "It is #{Calendar.format(now)}.",
      report.action && "Under way: #{doing(report.action, context)}.",
      planned(report.plan, context),
      abandoned(report.status, report, context),
      dropped(report.dropped)
    ]
    |> join()
  end

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")

  defp status(:done), do: "Done."

  defp status(:failed), do: "Failed."

  defp status(:interrupted),
    do: "Interrupted: something needs your attention. Your action goes on."

  defp status(:still_going), do: "Still going."
  defp status(:idle), do: "Nothing under way."

  defp planned([], _context), do: nil
  defp planned(plan, context), do: "Planned after it: #{steps_text(plan, context)}."

  defp abandoned(status, report, context) do
    case Map.get(report, :abandoned, []) do
      [] ->
        nil

      steps when status == :failed ->
        "The rest of the plan was dropped: #{steps_text(steps, context)}."

      steps when status == :yielded ->
        "It still had: #{steps_text(steps, context)}."

      steps ->
        "Dropped from your earlier plan: #{steps_text(steps, context)}."
    end
  end

  defp steps_text(steps, context) do
    {shown, rest} = Enum.split(steps, @shown_steps)
    more = if rest == [], do: [], else: ["and #{length(rest)} more"]
    Enum.join(Enum.map(shown, &step_text(&1, context)) ++ more, ", ")
  end

  defp problem(nil), do: nil

  defp problem({:ambiguous, query, names}),
    do: "\"#{query}\" could mean #{or_list(names)}; name it more fully."

  defp problem(reason), do: "A step could not be taken (#{inspect(reason)})."

  @doc "Names joined as a player says them: `A, B or C`."
  @spec or_list([String.t()]) :: String.t()
  def or_list([one]), do: one

  def or_list(names) do
    {init, [last]} = Enum.split(names, -1)
    Enum.join(init, ", ") <> " or " <> last
  end

  defp dropped(0), do: nil
  defp dropped(n), do: "(#{n} older percepts were dropped.)"

  # What a look tells about the report: names for ids, and the action the
  # body is doing (which carries a wait's end).
  defp context(nil, now), do: %{names: %{}, action: nil, now: now}

  defp context(look, now) do
    named =
      for list <- [look[:places], look[:hearths], look[:carried], look[:bodies]],
          is_list(list),
          %{id: id, name: name} <- list,
          do: {id, name}

    here = for %{id: id, name: name} <- [look[:here]], do: {id, name}

    action =
      for %{target: target, target_name: name} when is_binary(target) and is_binary(name) <-
            [look[:action]],
          do: {target, name}

    %{names: Map.new(named ++ here ++ action), action: look[:action], now: now}
  end

  # The step under way: the Mind's action, with what the look says of it.
  defp doing(action, context) do
    live = live(action, context)
    params = (live && live[:params]) || %{}

    case {action.verb, live && live[:until]} do
      {:wait, until} when is_integer(until) -> "wait until #{Prose.stamp(until, context.now)}"
      {verb, _until} -> describe(verb, name(action.target, context), params)
    end
  end

  # The look's action, when it is this one.
  defp live(%{ref: ref}, %{action: %{ref: ref} = live}), do: live
  defp live(_action, _context), do: nil

  defp step_text({verb, opts}, context) do
    target = opts[:target_name] || name(opts[:target], context)
    describe(verb, target, Keyword.get(opts, :params, %{}))
  end

  defp describe(:go, nil, _params), do: "go"
  defp describe(:go, target, _params), do: "go to #{target}"

  defp describe(:wait, _target, %{for: seconds}) when is_integer(seconds),
    do: "wait #{span(seconds)}"

  defp describe(:wait, _target, %{until: moment}), do: "wait until #{moment}"
  defp describe(:follow, _target, %{direction: dir}), do: "follow the channel #{dir}"
  defp describe(:walk, _target, %{direction: dir}) when is_binary(dir), do: "walk #{dir}"

  defp describe(verb, nil, _params) when verb in [:kindle, :douse],
    do: "#{verb} the nearest hearth"

  defp describe(:write, _target, _params), do: "write a page"
  defp describe(verb, nil, _params), do: to_string(verb)
  defp describe(verb, target, _params), do: "#{verb} #{target}"

  defp name(nil, _context), do: nil
  defp name(id, context), do: Map.get(context.names, id, id)

  defp span(seconds) when rem(seconds, 3_600) == 0, do: plural(div(seconds, 3_600), "hour")
  defp span(seconds) when rem(seconds, 60) == 0, do: plural(div(seconds, 60), "minute")
  defp span(seconds), do: plural(seconds, "second")

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(n, unit), do: "#{n} #{unit}s"

  @doc """
  A Mind report as JSON-ready data. With a look, the action carries its
  target's `target_name` and, for a wait, when it ends (`until`).
  """
  @spec data(map(), integer(), map() | nil) :: map()
  def data(report, now, look \\ nil) do
    context = context(look, now)

    %{
      status: report.status,
      time: Calendar.format(now),
      action: action_data(report.action, context),
      plan: Enum.map(report.plan, &step/1),
      abandoned: Enum.map(Map.get(report, :abandoned, []), &step/1),
      problem: problem_data(Map.get(report, :problem)),
      dropped: report.dropped,
      percepts: Enum.map(report.percepts, &percept(&1, now))
    }
  end

  defp problem_data(nil), do: nil
  defp problem_data({:ambiguous, query, names}), do: %{ambiguous: query, could_be: names}
  defp problem_data(reason), do: %{reason: inspect(reason)}

  defp action_data(nil, _context), do: nil

  defp action_data(action, context) do
    live = live(action, context)

    action
    |> Map.put(:target_name, name(action.target, context))
    |> then(fn data ->
      case live && live[:until] do
        until when is_integer(until) -> Map.put(data, :until, Calendar.format(until))
        _none -> data
      end
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> jsonable()
  end

  defp step({verb, opts}),
    do: %{
      verb: verb,
      target: step_target(opts),
      params: jsonable(Keyword.get(opts, :params, %{}))
    }

  # A planned step's target as given: an id, or a name not yet resolved.
  defp step_target(opts), do: opts[:target] || opts[:target_name]

  defp percept(percept, now) do
    percept
    |> Map.take([:kind, :type, :summary, :outcome, :reason, :issuer, :salience, :source, :data])
    |> Map.put(:time, Prose.stamp(percept.time, now))
    |> Map.put(:ref, percept.intent)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> jsonable()
  end

  @doc """
  A look as JSON-ready data: its time formatted (and a wait's end), and
  its measures rounded, temperatures (`*_c`) to 0.1 degree and the rest to
  two places.
  """
  @spec look(map()) :: map()
  def look(look) do
    look
    |> Map.drop([:away])
    |> Map.put(:time, Calendar.format(look.time))
    |> Map.update(:action, nil, &look_action/1)
    |> rounded()
    |> jsonable()
  end

  defp look_action(%{until: until} = action) when is_integer(until),
    do: %{action | until: Calendar.format(until)}

  defp look_action(action), do: action

  defp rounded(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, rounded(key, value)} end)

  defp rounded(list) when is_list(list), do: Enum.map(list, &rounded/1)
  defp rounded(other), do: other

  defp rounded(key, value) when is_float(value) do
    if key |> to_string() |> String.ends_with?("_c"),
      do: Float.round(value, 1),
      else: Float.round(value, 2)
  end

  defp rounded(_key, value), do: rounded(value)

  @doc "Makes a term encodable as JSON: tuples become lists."
  @spec jsonable(term()) :: term()
  def jsonable(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> jsonable()
  def jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, jsonable(v)} end)
  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  def jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  def jsonable(other), do: other
end
