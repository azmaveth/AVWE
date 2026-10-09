defmodule Avwe.Definition.Codec do
  @moduledoc """
  JSON to the terms `Avwe.Worldgen` takes, and back, by a description of each
  shape (a **type**). One description gives both directions, so what is
  written can always be read again.

  Decoding reports every problem it finds, not the first, each with the path
  to it in plain words, and **never makes an atom from the file**: a string
  becomes an atom only by being one of the names a type lists, and object keys
  are looked up among the keys a type lists.

  Types:

    * `:string`, `:integer`, `:number` (an integer stays an integer and a float
      a float), `:float` (any number, read as a float; written only from one),
      `{:nullable, type}`
    * `{:where, type, predicate, expectation}`: `type`, and what the value read
      must also satisfy; `expectation` says what was wanted when it does not
    * `{:atom, allowed}`, `{:atoms, allowed}`: a string from the list, as an atom
    * `{:list, type}`, `{:set, type}` (a `MapSet`)
    * `{:keyword, fields}`, `{:map, fields}`: an object with these keys, as a
      keyword list in the order of `fields` or as a map. A field is `{key,
      type}`, or `{key, {:opt, type}}` when it may be left out
    * `{:keyed, type}`: an object whose keys are anything, as `{key, value}` pairs
    * `:cell` (`[x, y]` as `{x, y}`), `:range` (`[first, last]` as `first..last`)
    * `:waypoint`, `{:place_entry, fields}`, `:calendar_time`, `:plan`, `:params`,
      `{:atom_map, keys, type}`: the shapes of the world's settings
    * `{:tagged, tag, variants}`: an object of one of several kinds, named by
      its `tag` key; `variants` is `[kind: type]`, and each variant's type holds
      the tag key itself
  """

  @directions [:north, :east, :south, :west]
  @verbs ~w(go follow walk wait say stop kindle douse write read rest)a
  @param_keys ~w(for until text volume direction distance_m last)a
  @untils ~w(dawn dusk sunrise sunset)a
  @volumes ~w(whisper talk shout)a
  @channel_directions ~w(upstream downstream)a

  @type type :: term()

  @doc "The four edges and compass sides a river or a waypoint can be given."
  @spec directions() :: [atom()]
  def directions, do: @directions

  # Decoding

  @doc "Reads `json` as `type`, or says everything wrong with it. `path` names where it is."
  @spec decode(type(), term(), String.t()) :: {:ok, term()} | {:error, [String.t()]}
  def decode(:string, value, _path) when is_binary(value), do: {:ok, value}
  def decode(:integer, value, _path) when is_integer(value), do: {:ok, value}
  def decode(:number, value, _path) when is_number(value), do: {:ok, value}
  def decode(:float, value, _path) when is_number(value), do: {:ok, value * 1.0}
  def decode({:nullable, _type}, nil, _path), do: {:ok, nil}
  def decode({:nullable, type}, value, path), do: decode(type, value, path)

  def decode({:where, type, predicate, expectation}, value, path) do
    with {:ok, decoded} <- decode(type, value, path) do
      if predicate.(decoded), do: {:ok, decoded}, else: bad(path, expectation, value)
    end
  end

  def decode({:atom, allowed}, value, path) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> bad(path, "one of #{names(allowed)}", value)
      atom -> {:ok, atom}
    end
  end

  def decode({:atoms, allowed}, value, path), do: decode({:list, {:atom, allowed}}, value, path)

  def decode({:list, type}, values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> decode(type, value, "#{path}[#{index}]") end)
    |> collect()
  end

  def decode({:set, type}, values, path) do
    with {:ok, list} <- decode({:list, type}, values, path), do: {:ok, MapSet.new(list)}
  end

  def decode({kind, fields}, %{} = object, path) when kind in [:keyword, :map],
    do: decode_object(kind, fields, object, path)

  def decode({:keyed, type}, %{} = object, path) do
    object
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> decode_pair(key, type, value, path) end)
    |> collect()
  end

  def decode(:cell, [x, y], _path) when is_integer(x) and is_integer(y), do: {:ok, {x, y}}

  def decode(:range, [first, last], _path)
      when is_integer(first) and is_integer(last) and first <= last,
      do: {:ok, first..last}

  def decode(:waypoint, place, _path) when is_binary(place), do: {:ok, place}

  def decode(:waypoint, %{} = object, path) do
    fields = [place: :string, beside: {:atom, @directions}, cells: :integer]

    with {:ok, [place: place, beside: beside, cells: cells]} <-
           decode({:keyword, fields}, object, path),
         do: {:ok, {place, beside: beside, cells: cells}}
  end

  def decode({:place_entry, fields}, %{} = object, path) do
    with {:ok, [{:place, place} | options]} <-
           decode({:keyword, [place: :string] ++ fields}, object, path),
         do: {:ok, {place, options}}
  end

  def decode(:calendar_time, seconds, _path) when is_integer(seconds), do: {:ok, seconds}

  def decode(:calendar_time, %{} = object, path) do
    with {:ok, [{:year, year} | options]} <- decode({:keyword, calendar_fields()}, object, path),
         do: {:ok, {year, options}}
  end

  def decode(:plan, [], path), do: bad(path, "a list of steps, at least one", [])
  def decode(:plan, steps, path) when is_list(steps), do: decode({:list, :step}, steps, path)

  def decode(:step, %{} = object, path) do
    fields = [verb: {:atom, @verbs}, target: {:opt, :string}, params: {:opt, :params}]

    with {:ok, [{:verb, verb} | options]} <- decode({:keyword, fields}, object, path),
         do: {:ok, if(options == [], do: {verb}, else: {verb, options})}
  end

  def decode(:params, %{} = object, path), do: decode_params(object, path)

  def decode({:atom_map, keys, type}, %{} = object, path) do
    object
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> decode_atom_key(keys, key, type, value, path) end)
    |> collect()
    |> then(fn
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end)
  end

  def decode({:tagged, tag, variants}, %{} = object, path) do
    key = Atom.to_string(tag)

    case Enum.find(variants, fn {kind, _type} -> Atom.to_string(kind) == object[key] end) do
      {_kind, type} ->
        decode(type, object, path)

      nil ->
        bad("#{here(path)}#{key}", "one of #{names(Keyword.keys(variants))}", object[key])
    end
  end

  def decode(type, value, path), do: bad(path, describe(type), value)

  defp decode_object(kind, fields, object, path) do
    known = Map.new(fields, fn {key, _type} -> {Atom.to_string(key), key} end)

    unknown =
      for key <- Enum.sort(Map.keys(object)), not Map.has_key?(known, key) do
        {:error,
         ["#{here(path)}#{key}: not a key of this (it has #{names(Keyword.keys(fields))})"]}
      end

    present = Enum.map(fields, &decode_field(&1, object, path))

    case collect(unknown ++ present) do
      {:ok, pairs} -> {:ok, shape(kind, Enum.reject(pairs, &(&1 == :absent)))}
      error -> error
    end
  end

  defp decode_field({key, type}, object, path) do
    {type, optional?} = optional(type)
    json_key = Atom.to_string(key)

    case Map.fetch(object, json_key) do
      {:ok, value} -> with_key(key, decode(type, value, "#{here(path)}#{json_key}"))
      :error when optional? -> {:ok, :absent}
      :error -> {:error, ["#{here(path)}#{json_key}: missing"]}
    end
  end

  defp with_key(key, {:ok, value}), do: {:ok, {key, value}}
  defp with_key(_key, error), do: error

  defp optional({:opt, type}), do: {type, true}
  defp optional(type), do: {type, false}

  defp shape(:keyword, pairs), do: pairs
  defp shape(:map, pairs), do: Map.new(pairs)

  defp decode_pair(key, type, value, path) do
    with {:ok, decoded} <- decode(type, value, "#{path}[#{inspect(key)}]"),
         do: {:ok, {key, decoded}}
  end

  defp decode_atom_key(keys, key, type, value, path) do
    case Enum.find(keys, &(Atom.to_string(&1) == key)) do
      nil ->
        {:error, ["#{here(path)}#{key}: not one of #{names(keys)}"]}

      atom ->
        with {:ok, decoded} <- decode(type, value, "#{here(path)}#{key}"),
             do: {:ok, {atom, decoded}}
    end
  end

  # The parameters of a step: a number, or a word from a short list, by name.
  defp decode_params(object, path) do
    object
    |> Enum.sort()
    |> Enum.map(fn {key, value} ->
      case Enum.find(@param_keys, &(Atom.to_string(&1) == key)) do
        nil -> {:error, ["#{here(path)}#{key}: not one of #{names(@param_keys)}"]}
        atom -> decode_param(atom, value, "#{here(path)}#{key}")
      end
    end)
    |> collect()
    |> then(fn
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end)
  end

  defp decode_param(:until, value, path), do: atom_param(:until, @untils, value, path)
  defp decode_param(:volume, value, path), do: atom_param(:volume, @volumes, value, path)
  defp decode_param(:text, value, path), do: typed_param(:text, :string, value, path)

  defp decode_param(:direction, value, path) when value in ["upstream", "downstream"],
    do: atom_param(:direction, @channel_directions, value, path)

  defp decode_param(:direction, value, path), do: typed_param(:direction, :string, value, path)
  defp decode_param(key, value, path), do: typed_param(key, :number, value, path)

  defp atom_param(key, allowed, value, path),
    do: with_key(key, decode({:atom, allowed}, value, path))

  defp typed_param(key, type, value, path), do: with_key(key, decode(type, value, path))

  # Encoding

  @doc """
  Writes `term` as JSON-ready data (maps with string keys, lists, strings and
  numbers) of `type`. A term the type cannot hold raises `ArgumentError` naming
  it, so what is exported is never silently different from what was given.
  """
  @spec encode(type(), term()) :: term()
  def encode(:string, value) when is_binary(value), do: value
  def encode(:integer, value) when is_integer(value), do: value
  def encode(:number, value) when is_number(value), do: value
  def encode(:float, value) when is_float(value), do: value
  def encode({:nullable, _type}, nil), do: nil
  def encode({:nullable, type}, value), do: encode(type, value)
  def encode({:where, type, _predicate, _expectation}, term), do: encode(type, term)
  def encode({:atom, allowed}, value) when is_atom(value), do: atom_name!(allowed, value)
  def encode({:atoms, allowed}, values), do: encode({:list, {:atom, allowed}}, values)
  def encode({:list, type}, values) when is_list(values), do: Enum.map(values, &encode(type, &1))

  def encode({:set, type}, %MapSet{} = values),
    do: values |> Enum.map(&encode(type, &1)) |> Enum.sort()

  def encode({kind, fields}, terms) when kind in [:keyword, :map],
    do: encode_object(fields, terms)

  def encode({:keyed, type}, pairs),
    do: Map.new(pairs, fn {key, value} -> {to_string(key), encode(type, value)} end)

  def encode(:cell, {x, y}) when is_integer(x) and is_integer(y), do: [x, y]
  def encode(:range, first..last//1), do: [first, last]
  def encode(:waypoint, place) when is_binary(place), do: place

  def encode(:waypoint, {place, options}),
    do:
      encode(
        {:keyword, [place: :string, beside: {:atom, @directions}, cells: :integer]},
        [place: place] ++ options
      )

  def encode({:place_entry, fields}, {place, options}),
    do: encode({:keyword, [place: :string] ++ fields}, [place: place] ++ options)

  def encode(:calendar_time, seconds) when is_integer(seconds), do: seconds

  def encode(:calendar_time, {year, options}) do
    encode({:keyword, calendar_fields()}, [year: year] ++ options)
  end

  def encode(:plan, steps) when is_list(steps), do: Enum.map(steps, &encode(:step, &1))

  def encode(:step, {verb}), do: %{"verb" => atom_name!(@verbs, verb)}

  def encode(:step, {verb, options}) when is_list(options) do
    if Keyword.keys(options) -- [:target, :params] != [] or
         options != Enum.sort_by(options, &step_order/1),
       do:
         raise(
           ArgumentError,
           "a step can carry target and then params, got #{inspect({verb, options})}"
         )

    fields = [verb: {:atom, @verbs}, target: {:opt, :string}, params: {:opt, :params}]
    encode({:keyword, fields}, [verb: verb] ++ options)
  end

  def encode(:params, %{} = params) do
    Map.new(params, fn {key, value} -> {atom_name!(@param_keys, key), param_value(key, value)} end)
  end

  def encode({:atom_map, keys, type}, %{} = map),
    do: Map.new(map, fn {key, value} -> {atom_name!(keys, key), encode(type, value)} end)

  def encode({:tagged, tag, variants}, terms) do
    case Keyword.fetch(variants, terms[tag]) do
      {:ok, type} ->
        encode(type, terms)

      :error ->
        raise ArgumentError,
              "cannot write #{inspect(tag)} #{inspect(terms[tag])}; it is not one of " <>
                names(Keyword.keys(variants))
    end
  end

  def encode(type, term),
    do: raise(ArgumentError, "cannot write #{inspect(term, limit: 8)} as #{describe(type)}")

  # A world time as a date: the day from 1, the hour and the minute on the clock.
  defp calendar_fields do
    [
      year: :integer,
      day: {:opt, {:where, :integer, &(&1 >= 1), "a day of the year, 1 or more"}},
      hour: {:opt, {:where, :integer, &(&1 in 0..23), "an hour, 0 to 23"}},
      minute: {:opt, {:where, :integer, &(&1 in 0..59), "a minute, 0 to 59"}}
    ]
  end

  defp step_order({:target, _}), do: 0
  defp step_order({:params, _}), do: 1

  defp encode_object(fields, terms) do
    terms = if is_map(terms), do: Map.to_list(terms), else: terms

    known = Enum.map(fields, &elem(&1, 0))

    case Keyword.keys(terms) -- known do
      [] ->
        :ok

      extra ->
        raise ArgumentError,
              "cannot write the keys #{inspect(extra)}; they are not among #{inspect(known)}"
    end

    for {key, type} <- fields, reduce: %{} do
      acc -> encode_field(acc, key, optional(type), terms)
    end
  end

  defp encode_field(acc, key, {type, optional?}, terms) do
    case List.keyfind(terms, key, 0) do
      {^key, value} ->
        Map.put(acc, Atom.to_string(key), encode(type, value))

      nil when optional? ->
        acc

      nil ->
        raise ArgumentError, "cannot write without #{inspect(key)}: #{inspect(terms, limit: 8)}"
    end
  end

  defp param_value(:until, value), do: atom_name!(@untils, value)
  defp param_value(:volume, value), do: atom_name!(@volumes, value)

  defp param_value(:direction, value) when is_atom(value),
    do: atom_name!(@channel_directions, value)

  defp param_value(:direction, value), do: encode(:string, value)
  defp param_value(:text, value), do: encode(:string, value)
  defp param_value(_key, value), do: encode(:number, value)

  defp atom_name!(allowed, atom) do
    if atom in allowed,
      do: Atom.to_string(atom),
      else: raise(ArgumentError, "#{inspect(atom)} is not one of #{names(allowed)}")
  end

  # Messages

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _value}, &1)) do
      {oks, []} -> {:ok, for({:ok, value} <- oks, do: value)}
      {_oks, errors} -> {:error, Enum.flat_map(errors, fn {:error, messages} -> messages end)}
    end
  end

  defp bad(path, expected, value),
    do:
      {:error,
       [
         "#{label(path)}: expected #{expected}, got " <>
           inspect(value, limit: 6, printable_limit: 40)
       ]}

  defp label(""), do: "the file"
  defp label(path), do: path

  defp here(""), do: ""
  defp here(path), do: path <> "."

  defp names(atoms), do: Enum.map_join(atoms, ", ", &"\"#{&1}\"")

  defp describe(:string), do: "a string"
  defp describe(:integer), do: "a whole number"
  defp describe(:number), do: "a number"
  defp describe(:float), do: "a number"
  defp describe({:where, _type, _predicate, expectation}), do: expectation
  defp describe(:cell), do: "a cell, [x, y]"
  defp describe(:range), do: "two whole numbers, [first, last], going up"
  defp describe({:nullable, type}), do: describe(type) <> " or null"
  defp describe({:atom, allowed}), do: "one of #{names(allowed)}"
  defp describe({:atoms, allowed}), do: "a list of #{names(allowed)}"
  defp describe({:list, _type}), do: "a list"
  defp describe({:set, _type}), do: "a list"
  defp describe({kind, _fields}) when kind in [:keyword, :map], do: "an object"
  defp describe({:keyed, _type}), do: "an object"
  defp describe({:atom_map, _keys, _type}), do: "an object"
  defp describe(:waypoint), do: "a place, or an object with place, beside and cells"
  defp describe({:place_entry, _fields}), do: "an object with a place"

  defp describe(:calendar_time),
    do: "a number of seconds, or an object with year, day, hour and minute"

  defp describe(:plan), do: "a list of steps"
  defp describe(:step), do: "a step: an object with a verb"
  defp describe(:params), do: "an object"
  defp describe({:tagged, _tag, _variants}), do: "an object"
  defp describe(other), do: inspect(other)
end
