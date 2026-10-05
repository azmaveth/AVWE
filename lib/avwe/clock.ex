defmodule Avwe.Clock do
  @moduledoc """
  A world's clock.

  Each tick steps every region once, in sorted order, and the next tick doesn't
  start until every region has finished. That is the barrier that lets
  neighbouring regions exchange borders between ticks.

  Modes:

    * `:manual` steps only when asked through `Avwe.step/2`. For tests and iex.
    * `{:live, interval_ms}` ticks every `interval_ms`. The clock never pauses.
  """

  use GenServer

  alias Avwe.RegionServer

  def start_link(opts) do
    world = Keyword.fetch!(opts, :world)
    GenServer.start_link(__MODULE__, opts, name: via(world))
  end

  @doc "Runs `ticks` ticks now and returns the world's step and time."
  @spec step(term(), pos_integer()) :: {:ok, %{step: non_neg_integer(), time: integer()}}
  def step(world, ticks) when is_integer(ticks) and ticks > 0 do
    GenServer.call(via(world), {:step, ticks}, :infinity)
  end

  defp via(world), do: {:via, Registry, {Avwe.Registry, {:clock, world}}}

  @impl true
  def init(opts) do
    state = %{
      world: Keyword.fetch!(opts, :world),
      regions: Keyword.fetch!(opts, :regions),
      mode: Keyword.fetch!(opts, :mode),
      last: nil
    }

    schedule(state.mode)
    {:ok, state}
  end

  @impl true
  def handle_call({:step, ticks}, _from, state) do
    state = Enum.reduce(1..ticks, state, fn _n, acc -> tick(acc) end)
    {:reply, {:ok, state.last}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state.mode)
    {:noreply, tick(state)}
  end

  defp tick(state) do
    last =
      Enum.reduce(state.regions, nil, fn region_id, _acc ->
        {:ok, status} = RegionServer.advance(state.world, region_id, 1)
        status
      end)

    %{state | last: last}
  end

  defp schedule({:live, interval_ms}), do: Process.send_after(self(), :tick, interval_ms)
  defp schedule(:manual), do: :ok
end
