defmodule Avwe.Systems.Discovery do
  @moduledoc """
  Bodies learn places they come close to.

  A body that comes within 30 m of a place it doesn't know learns the way
  there (it joins the body's `:knows`), and a `:discovered` event is emitted
  for it. This is how a forgotten place, such as the river's source, becomes
  known again.
  """

  @behaviour Avwe.System

  alias Avwe.{Event, Region, Space}

  @discover_cells 3

  @impl Avwe.System
  def run(region, _tick) do
    places =
      for id <- Region.with_components(region, [:place, :position]),
          do: {id, Region.get(region, id, :position)}

    region
    |> Region.with_components([:body, :position, :knows])
    |> Enum.reduce({region, []}, fn body, {acc, events} ->
      position = Region.get(acc, body, :position)
      knows = Region.get(acc, body, :knows)

      found =
        for {place, place_position} <- places,
            not MapSet.member?(knows, place),
            Space.distance(position, place_position) <= @discover_cells,
            do: place

      learned = Region.put_component(acc, body, :knows, Enum.into(found, knows))

      {learned,
       events ++ Enum.map(found, &Event.new(:discovered, entity: body, data: %{place: &1}))}
    end)
  end
end
