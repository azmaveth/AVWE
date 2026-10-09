defmodule Avwe.Test.RuleMaker do
  @moduledoc """
  Rules and systems made on the spot, for the tests of the composition check
  (`Avwe.Ruleset`): modules defined where they are used, with the callbacks the
  test gives and nothing else.
  """

  @doc "Defines a system module `name` whose id is `id`. It does nothing."
  defmacro defsystem(name, id) do
    quote do
      defmodule unquote(name) do
        @moduledoc false
        @behaviour Avwe.System

        @impl Avwe.System
        def system_id, do: unquote(id)

        @impl Avwe.System
        def run(region, _tick), do: {region, []}
      end
    end
  end

  @doc """
  Defines a rule module `name` with the id `id`, version "1.0", and each of the
  optional callbacks (`owns`, `provides`, `systems` ...) given in `callbacks`.
  """
  defmacro defrule(name, id, callbacks \\ []) do
    defs =
      for {callback, value} <- callbacks do
        quote do
          @impl Avwe.Rule
          def unquote(callback)(), do: unquote(value)
        end
      end

    quote do
      defmodule unquote(name) do
        @moduledoc false
        @behaviour Avwe.Rule

        @impl Avwe.Rule
        def id, do: unquote(id)

        @impl Avwe.Rule
        def version, do: "1.0"

        unquote_splicing(defs)
      end
    end
  end
end
