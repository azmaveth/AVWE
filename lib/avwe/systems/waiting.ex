defmodule Avwe.Systems.Waiting do
  @moduledoc """
  Finishes `:wait` actions once their time has come.
  """

  @behaviour Avwe.System

  alias Avwe.{Actions, Region, Tick}

  @impl Avwe.System
  def system_id, do: "play.waiting/step"

  @impl Avwe.System
  def run(region, tick) do
    now = Tick.end_time(tick)

    region
    |> Region.with_components([:action])
    |> Enum.filter(
      &match?(%{verb: :wait, until: until} when until <= now, Region.get(region, &1, :action))
    )
    |> Enum.reduce({region, []}, fn body, {acc, events} ->
      {acc, done} = Actions.complete(acc, body, :success, :done)
      {acc, events ++ done}
    end)
  end
end
