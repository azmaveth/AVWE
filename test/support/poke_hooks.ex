defmodule Avwe.Test.PokeHooks do
  @moduledoc """
  Hooks made for the tests of the kernel (`Avwe.Hooks`): a region that is
  started is given a poke (`Avwe.Test.Poke`) that counts the times it has been
  started, and whoever registered
  `:poke_hooks_probe` is told what the hooks were asked.
  """

  @behaviour Avwe.Hooks

  alias Avwe.Test.Poke

  @impl Avwe.Hooks
  def on_resume(region, context) do
    tell({:resumed, region.step, context})
    [Poke.new(:starts, Map.get(region.env, :starts, 0) + 1)]
  end

  @impl Avwe.Hooks
  def on_reconfigure(saved, given, context) do
    tell({:reconfigured, saved.step, given.step, context})
    :ok
  end

  defp tell(message) do
    if probe = Process.whereis(:poke_hooks_probe), do: send(probe, message)
    :ok
  end
end
