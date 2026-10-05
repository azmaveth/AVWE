defmodule Avwe.Event do
  @moduledoc """
  Something that happened in a region during a step.

  Events feed perception, the chronicle and the narrator. Systems create them
  with `new/2`. When a region collects them it fills in the region id, and the
  time if the system left it unset, so systems only set `time` when they know
  the exact moment.
  """

  @enforce_keys [:type]
  defstruct [:type, :time, :region, :entity, data: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          time: Avwe.Calendar.time() | nil,
          region: term(),
          entity: String.t() | nil,
          data: map()
        }

  @doc """
  Creates an event. Options: `:time`, `:entity`, `:data`.
  """
  @spec new(atom(), keyword()) :: t()
  def new(type, opts \\ []) do
    %__MODULE__{
      type: type,
      time: opts[:time],
      entity: opts[:entity],
      data: Keyword.get(opts, :data, %{})
    }
  end
end
