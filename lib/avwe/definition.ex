defmodule Avwe.Definition do
  @moduledoc """
  A world as data: one JSON file, `priv/worlds/<name>/definition.json`, holding
  everything that makes a world this world and not another: its places and
  bodies, its terrain, its hearths, its miracles, what its characters do on
  their own, where guests arrive. The file is what a world is run from; Quire
  is what it was compiled from (`Avwe.Definition.Export`), and is not read when
  a world runs.

  The shape of the file is `Avwe.Definition.Schema`. **It is data and never
  code**: loading builds terms from what the schema lists and nothing else,
  makes no atom from the file, and reports every problem it finds, each with
  the path to it. A file that names something the engine has not been taught
  (a verb, a component, a norm) is refused; teaching it is a change to the
  schema, reviewed like any other.

  A definition's `hash/1` is over its data, not its text, so a file laid out
  differently is the same definition (and over all of it but the guests, which
  are how a world is run). A world started from a definition records the hash
  in its snapshots (`Avwe.Store`), and a saved world refuses to start under a
  different one.

  Pure: `from_json/1` and `decode/1` build one from a file's text or its terms
  (`Avwe.Definitions.load/1` reads the file); `region/2` builds the world's
  starting region; `encode/1`, `to_json/1` and `hash/1` write it out.
  """

  alias Avwe.{Calendar, Region, Worldgen}
  alias Avwe.Definition.{Check, Codec, Json, Schema}

  @default_dt 60

  @enforce_keys [:id, :name, :seed, :start]
  defstruct [
    :id,
    :name,
    :tagline,
    :description,
    :seed,
    :start,
    dt: @default_dt,
    ruleset: nil,
    entities: [],
    settings: [],
    guests: nil
  ]

  @typedoc """
  `entities` are `{id, components}` sorted by id; `settings` are the terms
  `Avwe.Worldgen.build/3` takes (`:terrain`, `:hearths`, `:miracles`,
  `:climate`, `:characters`), those the file gives, in that order; `guests` is
  `[arrival: place, max: n]` or `nil`; `start` is a date, `{year, opts}`, or a
  time in seconds; `ruleset` is what the file says of the rules the world runs
  (`[preset: name, with: ids, without: ids]` or `[rules: ids]`), or `nil` for
  the default preset (`Avwe.Ruleset`).
  """
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          tagline: String.t() | nil,
          description: String.t() | nil,
          seed: integer(),
          start: {integer(), keyword()} | integer(),
          dt: pos_integer(),
          ruleset: keyword() | nil,
          entities: [{String.t(), map()}],
          settings: keyword(),
          guests: keyword() | nil
        }

  @type reason ::
          {:invalid_definition, Path.t(), [String.t()]}
          | {:read_definition, Path.t(), term()}
          | {:bad_definition_name, String.t()}

  # Reading

  @doc "Reads a definition from its JSON text, or says everything wrong with it."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def from_json(text) do
    case JSON.decode(text) do
      {:ok, json} -> decode(json)
      {:error, reason} -> {:error, ["the file is not JSON: #{inspect(reason)}"]}
    end
  end

  @doc """
  Reads a definition from the terms JSON decodes to: the shapes first, and
  when they are right, the references (`Avwe.Definition.Check`).
  """
  @spec decode(term()) :: {:ok, t()} | {:error, [String.t()]}
  def decode(json) do
    with {:ok, top} <- Codec.decode(Schema.top(), json, ""),
         definition = build(top),
         [] <- Check.problems(definition) do
      {:ok, definition}
    else
      {:error, problems} -> {:error, problems}
      problems when is_list(problems) -> {:error, problems}
    end
  end

  defp build(top) do
    %__MODULE__{
      id: top.id,
      name: top.name,
      tagline: top[:tagline],
      description: top[:description],
      seed: top.seed,
      start: top.start,
      dt: Map.get(top, :dt, @default_dt),
      ruleset: top[:ruleset],
      entities: top |> Map.get(:entities, []) |> Enum.map(&entity/1) |> Enum.sort(),
      settings: settings(top),
      guests: top[:guests]
    }
  end

  defp entity(components) do
    {id, rest} = Map.pop!(components, :id)
    {id, rest}
  end

  # The terms `Avwe.Worldgen.build/3` takes, those the file gives, in a fixed
  # order. No terrain at all differs from an empty one (a land with no river),
  # so only `nil` is left out of it; no hearths and none at all are the same.
  defp settings(top) do
    rules = Map.get(top, :rules, %{})

    [
      terrain: rules[:"earthlike.valley"],
      hearths: get_in(rules, [:"earthlike.fire", :hearths]),
      miracles: top[:miracles],
      climate: rules[:"earthlike.weather"],
      characters: top[:characters]
    ]
    |> Enum.reject(fn
      {:terrain, terrain} -> terrain == nil
      {_key, value} -> value in [nil, []]
    end)
  end

  # Writing

  @doc """
  The definition as JSON-ready data: maps with string keys, lists, strings and
  numbers. Raises `ArgumentError` for anything the schema cannot write, so
  what is exported is never different from what was given.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = definition) do
    Codec.encode(Schema.top(), terms(definition))
  end

  defp terms(definition) do
    %{
      schema: Schema.version(),
      id: definition.id,
      name: definition.name,
      seed: definition.seed,
      dt: definition.dt,
      start: definition.start,
      entities: for({id, components} <- definition.entities, do: Map.put(components, :id, id))
    }
    |> put_unless_nil(:tagline, definition.tagline)
    |> put_unless_nil(:description, definition.description)
    |> put_unless_nil(:ruleset, definition.ruleset)
    |> put_unless_nil(:rules, rules(definition.settings))
    |> put_unless_nil(:miracles, miracles(definition.settings))
    |> put_unless_nil(:characters, definition.settings[:characters])
    |> put_unless_nil(:guests, definition.guests)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, _key, []), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp rules(settings) do
    rules =
      [
        "earthlike.valley": settings[:terrain],
        "earthlike.fire": settings[:hearths] && [hearths: settings[:hearths]],
        "earthlike.weather": settings[:climate]
      ]
      |> Enum.reject(fn {_rule, parameters} -> parameters == nil end)
      |> Map.new()

    if rules == %{}, do: nil, else: rules
  end

  # A miracle that does not say what kind it is is an event.
  defp miracles(settings),
    do: for(miracle <- settings[:miracles] || [], do: Keyword.put_new(miracle, :kind, :event))

  @doc "The definition as the text of a file: indented, readable, deterministic."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = definition), do: definition |> encode() |> Json.pretty()

  @doc """
  The definition's hash: SHA-256 (lower-case hex) of its data in canonical
  form. Two files that read as the same definition have the same hash,
  whatever their layout.

  It covers what the world is, and leaves out `guests`: who may arrive and
  where is how a world is run, as its clock is, and a saved world takes the
  guests it is started to take (`docs/m3-spec.md`). Raising the most a world
  takes must not strand it.
  """
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = definition) do
    canonical = definition |> encode() |> Map.delete("guests") |> Json.compact()
    :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower)
  end

  # Building

  @doc """
  The world's starting region. Options: `:id` (the region's id, required) and
  `:systems` (run in order every step; default none, since the systems are code
  and not part of what a world is: `Avwe.start_world/2` gives its own).
  """
  @spec region(t(), keyword()) :: Region.t()
  def region(%__MODULE__{} = definition, opts) do
    [
      id: Keyword.fetch!(opts, :id),
      seed: definition.seed,
      time: time(definition.start),
      dt: definition.dt,
      systems: Keyword.get(opts, :systems, [])
    ]
    |> Region.new()
    |> put_entities(definition.entities)
    |> Worldgen.build(definition.settings)
  end

  defp put_entities(region, entities) do
    Enum.reduce(entities, region, fn {id, components}, acc ->
      Region.put_entity(acc, id, components)
    end)
  end

  @doc "A start, as the world time it is."
  @spec time({integer(), keyword()} | integer()) :: Calendar.time()
  def time({year, opts}), do: Calendar.at(year, opts)
  def time(seconds) when is_integer(seconds), do: seconds

  @doc """
  An error from `Avwe.Definitions.load/1` or `Avwe.start_world/2` in plain words, one problem to a line, for a person
  who runs the world.
  """
  @spec explain(term()) :: String.t()
  def explain({:invalid_definition, path, problems}),
    do:
      Enum.join(
        ["#{path} is not a valid world definition:" | Enum.map(problems, &("  " <> &1))],
        "\n"
      )

  def explain({:invalid_ruleset, problems}),
    do:
      Enum.join(
        ["the world's rules do not make a world:" | Enum.map(problems, &("  " <> &1))],
        "\n"
      )

  def explain({:read_definition, path, reason}),
    do: "cannot read the definition #{path}: #{:file.format_error(reason)}"

  def explain({:bad_definition_name, name}),
    do:
      "#{inspect(name)} is not a definition name (lower-case letters, digits, - and _) or a path to a .json file"

  def explain(:definition_and_quire),
    do: "a world is started from a definition or from a Quire folder, not both"

  def explain(:no_world_source),
    do:
      "a world needs a definition (definition: a name or a path) or a Quire folder (quire: a path)"

  def explain({:settings_with_definition, keys}),
    do:
      "#{Enum.map_join(keys, ", ", &inspect/1)} cannot be given beside a definition: " <>
        "the definition is the whole of the world, so change the definition"

  def explain(other), do: inspect(other)
end
