defmodule Avwe.Percept do
  @moduledoc """
  Something a body perceives, ready for any client.

  `summary` is plain prose every client can show as it is. The other fields
  let richer clients and agents use the percept without parsing prose.

  Kinds:

    * `:sensed` - something the body noticed without asking: speech, someone
      arriving, the sun rising.
    * `:progress` - an action of the body's own is under way.
    * `:result` - an intent has finished. `intent` is its ref and `outcome`
      uses Arbor's vocabulary: `:success`, `:failure`, `:blocked`,
      `:interrupted`. Every intent gets exactly one.

  `type` is the world event the percept came from. `source` describes where a
  sensed percept came from: `%{ref, distance_m, direction}`.
  """

  @enforce_keys [:kind, :type, :time]
  defstruct [
    :id,
    :kind,
    :type,
    :time,
    :body,
    :modality,
    :source,
    :intent,
    :outcome,
    :reason,
    :progress,
    :summary,
    confidence: 1.0,
    salience: 0.5
  ]

  @type kind :: :sensed | :progress | :result

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: kind(),
          type: atom(),
          time: Avwe.Calendar.time(),
          body: String.t() | nil,
          modality: :sight | :hearing | :smell | nil,
          source: map() | nil,
          intent: String.t() | nil,
          outcome: :success | :failure | :blocked | :interrupted | nil,
          reason: atom() | nil,
          progress: float() | nil,
          summary: String.t() | nil,
          confidence: float(),
          salience: float()
        }
end
