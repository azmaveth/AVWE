defmodule Avwe.KernelTest do
  @moduledoc """
  The simulation kernel names nothing that lives above it: not a module of the
  agent layer or of a rule, and not a word for a body, a percept, an intent or
  a piece of Earth-like physics (`docs/engine-spec.md`, 6 and 10). While the
  kernel is files in this project the test reads them; once it is a project of
  its own the compiler holds the first half and this holds the second.
  """

  use ExUnit.Case, async: true

  alias Avwe.Test.Boundary

  # The kernel: time, state, systems, inputs, the journal, running a world,
  # rules and their check, and the one system and rule every world has.
  @files ~w(
    region tick rng event system system_table calendar space store region_server world
    clock input hooks rule rule_package ruleset rules/sim systems/miracles
  )

  # The names of the registries the kernel starts and uses.
  @names ["Avwe.Registry", "Avwe.PubSub"]

  @agent_words ~w(body bodies percept percepts intent intents)
  @physics_words ~w(earthlike earth-like hearth hearths river rivers smoke silt kiln kilns
                    weather spring wind heat fire)

  defp path(file), do: Path.expand("../../lib/avwe/#{file}.ex", __DIR__)

  defp module(file) do
    "Avwe." <> (file |> String.split("/") |> Enum.map_join(".", &Macro.camelize/1))
  end

  test "the kernel refers to nothing but the kernel" do
    kernel = MapSet.new(@files, &module/1) |> MapSet.union(MapSet.new(@names))

    for file <- @files do
      outside = file |> path() |> Boundary.references() |> MapSet.difference(kernel)

      assert MapSet.to_list(outside) == [],
             "#{file}.ex refers to #{Enum.join(outside, ", ")}, which is not the kernel's"
    end
  end

  test "the kernel names no body, percept or intent, and no Earth-like physics" do
    for file <- @files do
      assert Boundary.words(path(file), @agent_words ++ @physics_words) == [],
             "#{file}.ex uses a word that is not the kernel's"
    end
  end

  test "the kernel's module list is every file of it that exists" do
    for file <- @files, do: assert(File.exists?(path(file)), "#{file}.ex is not there")
  end
end
