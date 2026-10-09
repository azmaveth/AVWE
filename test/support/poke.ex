defmodule Avwe.Test.Poke do
  @moduledoc """
  An input made for the tests of the kernel (`Avwe.Input`): it sets one value
  in the region's environment and says so in an event. With it the hooks that
  sim offers are tested without the agent layer: `group` is what inputs are
  ordered by, `refuse` makes it refuse to be submitted, and `derived` makes it
  one a system might have made.
  """

  alias Avwe.{Event, Region}

  @enforce_keys [:key, :value]
  defstruct [:key, :value, :refuse, group: 0, derived: false, seq: 0]

  @type t :: %__MODULE__{
          key: atom(),
          value: term(),
          refuse: term(),
          group: term(),
          derived: boolean(),
          seq: non_neg_integer()
        }

  @doc "A poke that sets `key` to `value`; options are the other fields."
  @spec new(atom(), term(), keyword()) :: t()
  def new(key, value, opts \\ []), do: struct!(__MODULE__, [key: key, value: value] ++ opts)

  defimpl Avwe.Input do
    def handle(poke, region, _tick) do
      event =
        Event.new(:poked,
          data: %{key: poke.key, value: poke.value, seq: poke.seq, group: poke.group}
        )

      {Region.put_env(region, poke.key, poke.value), [event]}
    end

    def order_key(poke), do: poke.group
    def validate(%{refuse: nil}, _region), do: :ok
    def validate(%{refuse: reason}, _region), do: {:error, reason}
    def derived?(poke), do: poke.derived
    def seq(poke), do: poke.seq
    def put_seq(poke, seq), do: %{poke | seq: seq}
  end
end
