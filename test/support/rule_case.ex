defmodule Avwe.RuleCase do
  @moduledoc """
  The model half of the conformance suite (`docs/engine-spec.md`, 6): what a
  rule's systems do to a region, checked against what its manifest
  (`Avwe.Rule`) says.

  `written_keys/2` runs one system for one step on a region and says which
  pieces of state it changed: components, fields, env values and the terrain.
  What the kernel keeps itself (the step, the time, the inboxes) is not state in
  this sense. A rule's systems should write only the keys it owns, and the
  suite checks it by running each system, from the states a real world is
  in, and comparing.
  """

  alias Avwe.Region

  @doc "The state keys that differ between two regions."
  @spec changed(Region.t(), Region.t()) :: MapSet.t(Avwe.Rule.key())
  def changed(%Region{} = before, %Region{} = after_) do
    differing(:component, before.components, after_.components)
    |> MapSet.union(differing(:field, before.fields, after_.fields))
    |> MapSet.union(differing(:env, before.env, after_.env))
    |> MapSet.union(
      if before.terrain == after_.terrain, do: MapSet.new(), else: MapSet.new([:terrain])
    )
  end

  defp differing(kind, before, after_) do
    names = Enum.uniq(Map.keys(before) ++ Map.keys(after_))

    for name <- names, Map.get(before, name) != Map.get(after_, name), into: MapSet.new() do
      {kind, name}
    end
  end

  @doc """
  Runs `region` forward `steps` steps and measures what each of its systems
  writes, each in its place in the step and so seeing what the systems before it
  did: `%{system_id => MapSet of keys}`, over the whole run.
  """
  @spec survey(Region.t(), pos_integer()) :: %{String.t() => MapSet.t()}
  def survey(%Region{systems: systems} = region, steps) do
    written = Map.new(systems, fn {id, _options} -> {id, MapSet.new()} end)
    key = {__MODULE__, make_ref()}
    Process.put(key, written)

    observe = fn id, before, after_ ->
      Process.put(
        key,
        Map.update!(Process.get(key), id, &MapSet.union(&1, changed(before, after_)))
      )
    end

    _advanced = Region.advance(region, steps, observe: observe)
    Process.delete(key)
  end
end
