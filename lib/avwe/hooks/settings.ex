defmodule Avwe.Hooks.Settings do
  @moduledoc """
  The settings a world made from Quire and settings is started with
  (`Avwe.Worldgen`: seed, climate, hearths, miracles, characters) are state
  once the world has been saved, so a world that is started again with other
  settings ignores them, and says which, in the log. A world made from a
  definition has nothing to compare: the definition is the same one, or the
  world refuses to start (`Avwe.RegionServer`).
  """

  @behaviour Avwe.Hooks

  alias Avwe.Region

  require Logger

  @impl Avwe.Hooks
  def on_reconfigure(saved, given, %{definition: definition, dir: dir}) do
    for {setting, phrase, wanted, kept} <- ignored_settings(saved, given, definition) do
      Logger.warning(
        "Region #{inspect(saved.id)}: ignoring :#{setting} #{inspect(wanted)}; " <>
          "the world's #{phrase} #{inspect(kept)}; delete #{dir} to start over"
      )
    end

    :ok
  end

  # The settings of `given` that the saved world cannot take on, as
  # `{setting, "what is", wanted, kept}` for the warning.
  defp ignored_settings(_saved, _given, definition) when definition != nil, do: []

  defp ignored_settings(saved, given, nil) do
    lit = lit_hearths(saved)

    [
      {:seed, "seed is", & &1.seed},
      {:climate, "wind is", &Map.get(&1.env, :wind)},
      {:hearths, "hearths are", &hearths(&1, lit)},
      {:miracles, "miracles are", &miracles/1},
      {:characters, "characters are", &characters/1}
    ]
    |> Enum.map(fn {setting, phrase, declared} ->
      {setting, phrase, declared.(given), declared.(saved)}
    end)
    |> Enum.reject(fn {_setting, _phrase, wanted, kept} -> wanted == kept end)
  end

  # A hearth as declared: its power and the wood laid in it. A hearth that
  # has been lit has burned some of that wood, so for those (`lit`) the fuel
  # is state by now and only the power is compared. Standing miracles carry
  # a hearth too, but are declared as miracles.
  defp hearths(region, lit) do
    for id <- Region.with_components(region, [:hearth]),
        Region.get(region, id, :miracle) == nil,
        into: %{} do
      keys = if id in lit, do: [:power_w], else: [:fuel_kg, :power_w]
      {id, region |> Region.get(id, :hearth) |> Map.take(keys)}
    end
  end

  defp lit_hearths(region) do
    for id <- Region.with_components(region, [:hearth]),
        Region.get(region, id, :hearth).lit_at != nil,
        do: id
  end

  # A miracle as declared: everything but when it was applied.
  defp miracles(region) do
    for id <- Region.with_components(region, [:miracle]), into: %{} do
      {id, region |> Region.get(id, :miracle) |> Map.delete(:applied_at)}
    end
  end

  # A character as declared: the routine and norms of every body that has
  # any, and the ids of the items it carries (what is written in a notebook
  # is state, not declaration). A guest is not declared: it arrived.
  defp characters(region) do
    carried =
      region
      |> Region.with_components([:item, :carried_by])
      |> Enum.group_by(&Region.get(region, &1, :carried_by))

    for id <- Region.with_components(region, [:body]),
        Region.get(region, id, :guest) == nil,
        declared = Map.take(Region.entity(region, id), [:routine, :norms]),
        declared = put_carries(declared, carried[id]),
        declared != %{},
        into: %{},
        do: {id, declared}
  end

  defp put_carries(declared, nil), do: declared
  defp put_carries(declared, items), do: Map.put(declared, :carries, items)
end
