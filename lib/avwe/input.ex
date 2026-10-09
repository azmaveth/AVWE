defprotocol Avwe.Input do
  @moduledoc """
  What the simulation knows of the outside: things arrive from it, are queued
  in a region's inbox, and are applied at the start of the next step. It does
  not know what they are. The agent layer's commands are one kind; a
  continuous control (a held steering vector) could be another, and the tests of
  the kernel use one of their own.

  An input is a struct that implements this protocol:

    * `handle/3` applies it to the region: `{region, events}`;
    * `order_key/1` says where it stands among the inputs of one step: they are
      applied sorted by `{order_key, seq}`, so the inputs of one key keep the
      order they were submitted in and the order of the keys is the same
      however the inputs arrived;
    * `validate/2` says whether the region would take it now, asked when it is
      submitted and before it is journaled, so a refusal is never in the log;
    * `derived?/1` is true for an input a system made inside the step (it is
      derived state: never journaled, regenerated on replay, and kept in a
      snapshot taken between steps);
    * `seq/1` and `put_seq/2` are the number the region gave it when it received
      it (`Avwe.Region.submit/2`), which the journal records and replay checks.

  The journal records inputs as opaque terms with the `seq` the region gave
  them (`Avwe.Store`), and sim looks inside none of them.
  """

  @doc "Applies the input at the start of a step."
  @spec handle(t(), Avwe.Region.t(), Avwe.Tick.t()) :: {Avwe.Region.t(), [Avwe.Event.t()]}
  def handle(input, region, tick)

  @doc "What the inputs of a step are sorted by, before their sequence numbers."
  @spec order_key(t()) :: term()
  def order_key(input)

  @doc "Whether the region would take the input now: `:ok`, or the reason it would not."
  @spec validate(t(), Avwe.Region.t()) :: :ok | {:error, term()}
  def validate(input, region)

  @doc "True for an input a system made during a step."
  @spec derived?(t()) :: boolean()
  def derived?(input)

  @doc "The sequence number the region gave the input."
  @spec seq(t()) :: non_neg_integer()
  def seq(input)

  @doc "The input, numbered."
  @spec put_seq(t(), non_neg_integer()) :: t()
  def put_seq(input, seq)
end
