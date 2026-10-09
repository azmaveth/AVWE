defmodule Avwe.Intent do
  @moduledoc """
  A controller's request for its body to do something.

  `ref` identifies the intent. Its outcome always comes back as exactly one
  result percept carrying the same ref. Intents wait in the region's inbox and
  are applied at the start of the next step, sorted by `{body, seq}`; the
  region assigns `seq` when it receives the intent.

  Verbs:

    * `:go` - walk to a place the body knows. `target` is the place's id.
    * `:follow` - follow the river channel to its head or its end. `params`:
      `%{direction: :upstream | :downstream}`. Blocked with `:no_channel`
      when the body is not near the channel, `:invalid` without a direction.
    * `:walk` - walk a distance in a compass direction. `params`:
      `%{direction: "north" | ... | "north-west", distance_m: metres}`
      (10 to 2 000; 100 when left out). Blocked with `:edge` at the map's
      edge, `:invalid` otherwise.
    * `:wait` - let time pass. `params`: `%{for: seconds}` or
      `%{until: :dawn | :dusk}`.
    * `:say` - speak. `params`: `%{text: text, volume: :whisper | :talk | :shout}`.
    * `:stop` - stop the current action.
    * `:kindle` - light a hearth within 20 m. `target` is the hearth's id, or
      `nil` for the nearest. Blocked with `:no_hearth`, `:no_such_hearth`,
      `:too_far`, `:already_burning` or `:no_fuel`.
    * `:douse` - put a hearth out; same target rule. Blocked with
      `:not_burning`; fails with `:unquenchable` when the fire won't go out.
    * `:write` - write a page in a notebook the body carries. `params`:
      `%{text: text}`, 1 to 1 000 characters once line breaks and tabs
      are made single spaces, other control characters dropped and the
      ends trimmed. `target` is the notebook's id, or `nil` for the one it
      carries (the first by id). The page is `%{time, text}`, stamped with
      the step's end, the time its result reports. Blocked with
      `:no_notebook` when the body carries no such notebook, `:invalid` for
      bad text, `:full` when the notebook holds 500 pages.
    * `:read` - read the last pages of a notebook the body carries; same
      target rule. `params`: `%{last: n}`, 1 to 50 (10 when left out). The
      result's data carries `pages: [%{time, text}]`, the last `n` oldest
      first, and `total`, the number of pages written. Blocked with
      `:no_notebook` or `:invalid`.
    * `:control` - the intent's `controller` takes the body: its `:control`
      component records the holder, and autopilot leaves it alone.
      `Avwe.Session` submits it when it claims a body. Succeeds with
      `:already` when that controller holds it; blocked with `:invalid`
      without a controller.
    * `:release` - the body is nobody's again and goes back to its routine.
      Succeeds with `:already` when nobody held it.
    * `:arrive` - a guest comes into the world (`Avwe.Guests`): the intent's
      `body` is the id the guest will have, and its `params` are `%{name:,
      backstory:, arrival:, max:}`, cleaned and checked. The one verb for a
      body that does not exist yet; the body is made at the arrival place.
      `Avwe.Session` submits it when a controller asks to arrive as a guest.
      Blocked with `:invalid_name`, `:invalid_backstory`, `:name_taken`,
      `:full`, `:no_guests` or `:no_arrival_place`.

  `controller` names the kind of controller behind the intent: `:human`,
  `:mcp`, `:arbor` or `:autopilot`.
  """

  @enforce_keys [:ref, :body, :verb]
  defstruct [:ref, :body, :verb, :target, :controller, params: %{}, seq: 0]

  @type verb ::
          :go
          | :follow
          | :walk
          | :wait
          | :say
          | :stop
          | :kindle
          | :douse
          | :write
          | :read
          | :control
          | :release
          | :arrive
          | atom()

  @type t :: %__MODULE__{
          ref: String.t(),
          body: String.t(),
          verb: verb(),
          target: String.t() | nil,
          controller: atom() | nil,
          params: map(),
          seq: non_neg_integer()
        }

  @doc "Creates an intent. Options: `:ref` (required), `:target`, `:params`, `:controller`."
  @spec new(String.t(), verb(), keyword()) :: t()
  def new(body, verb, opts) do
    %__MODULE__{
      ref: Keyword.fetch!(opts, :ref),
      body: body,
      verb: verb,
      target: opts[:target],
      params: Keyword.get(opts, :params, %{}),
      controller: opts[:controller]
    }
  end
end

defimpl Avwe.Input, for: Avwe.Intent do
  @moduledoc false

  alias Avwe.{Actions, Event, Guests, Intent, Region, Tick}

  # An intent is applied by the body it is for, and a body's intents in the
  # order they were submitted.
  @spec handle(Intent.t(), Region.t(), Tick.t()) :: {Region.t(), [Event.t()]}
  def handle(intent, region, tick), do: Actions.handle(region, intent, tick)

  @spec order_key(Intent.t()) :: String.t()
  def order_key(intent), do: intent.body

  # A guest's arrival is checked against the guests there and the arrivals
  # waiting; the rest are checked as they are applied, and answered with a
  # result.
  @spec validate(Intent.t(), Region.t()) :: :ok | {:error, term()}
  def validate(%{verb: :arrive} = intent, region), do: Guests.check(region, intent)
  def validate(_intent, _region), do: :ok

  # Autopilot's refs are the mark of an intent it made.
  @spec derived?(Intent.t()) :: boolean()
  def derived?(%{ref: ref}), do: String.starts_with?(ref, "auto-")

  @spec seq(Intent.t()) :: non_neg_integer()
  def seq(intent), do: intent.seq

  @spec put_seq(Intent.t(), non_neg_integer()) :: Intent.t()
  def put_seq(intent, seq), do: %{intent | seq: seq}
end
