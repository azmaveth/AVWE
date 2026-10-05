defmodule Avwe.Test.Fixtures do
  @moduledoc "Paths to test fixtures."

  @doc "The Ember Reach as a Quire world folder."
  def ember_reach, do: Path.expand("../fixtures/quire/ember-reach", __DIR__)
end
