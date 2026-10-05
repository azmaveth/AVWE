defmodule Avwe.Test.Fixtures do
  @moduledoc "Test worlds and helpers for receiving percepts."

  import ExUnit.Assertions

  @doc "The Ember Reach as a Quire world folder."
  def ember_reach, do: Path.expand("../fixtures/quire/ember-reach", __DIR__)

  @doc """
  Lantern Hollow, a small test world. Wren and Tamsin live on Hollow Green,
  Pell at the Mill Pond 70 m away (in earshot of a shout, not of talk), and
  Odo in the Far Tower 1.5 km away (out of sight and hearing).
  """
  def lantern_hollow, do: Path.expand("../fixtures/quire/lantern-hollow", __DIR__)

  @doc """
  Every percept the session has sent to the calling process so far.

  Calls the session first, so it has handled every world event sent before
  this call, and its percepts are already in the mailbox.
  """
  def percepts(session) do
    _body = Avwe.Session.body(session)
    drain(session)
  end

  @doc "The summaries of `percepts/1`."
  def summaries(session), do: session |> percepts() |> Enum.map(& &1.summary)

  @doc "Waits until `fun` returns a truthy value, polling every 10 ms."
  def eventually(fun, timeout \\ 1_000) do
    poll(fun, System.monotonic_time(:millisecond) + timeout)
  end

  defp drain(session) do
    receive do
      {:avwe_percepts, ^session, percepts} -> percepts ++ drain(session)
    after
      0 -> []
    end
  end

  defp poll(fun, deadline) do
    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Condition not met in time")

      true ->
        Process.sleep(10)
        poll(fun, deadline)
    end
  end
end
