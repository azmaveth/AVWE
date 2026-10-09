defmodule Avwe.Definition.Schema do
  @moduledoc """
  The shape of a world definition file (`Avwe.Definition`), version 1, as the
  types `Avwe.Definition.Codec` reads and writes.

  The file is one JSON object:

    * `schema` (the version, 1), `id`, `name`, and optionally `tagline` and
      `description`: what the world is called
    * `seed` and `start` (a date, `{"year": 813, "day": 220, "hour": 4}`, or a
      number of seconds) and optionally `dt` (seconds of world time to a step,
      60): the numbers the world begins from
    * `ruleset` (optional): the rules the world runs, as a preset with rules
      added and left out (`{"preset": "earthlike", "without": ["earthlike.smoke"]}`)
      or an explicit list (`{"rules": ["play", "earthlike.fire"]}`); the Earth-like
      preset when it is left out (`Avwe.Ruleset`)
    * `rules`: what each rule is told, by its id. `earthlike.valley` takes the
      terrain (a `river`, `rises` and `clay`), `earthlike.fire` the `hearths`
      and `earthlike.weather` the `wind`. The ids are those of the rules
      (`Avwe.Rules.Earthlike`), and a rule that is told something must be one
      the world runs (`ruleset`)
    * `entities`: the places and bodies, by id, with their components (`place`,
      `position`, `repr`, `article`, `body`, `knows`, `home`): what
      `Avwe.Quire.Seed` builds from a Quire world
    * `miracles`: events at a time (`kind: "event"`) and standing miracles
      (`kind: "standing"`)
    * `characters`: by body id, what the body does on its own: `norms`,
      `carries`, a `routine`, a `glyph` and a `color`
    * `guests`: where guests arrive and how many (`arrival`, `max`)

  Everything a file may name is listed here (verbs, norms, item kinds, the
  components a miracle may change), so a file cannot name what the engine has
  not been taught: a new one is a change to this module, reviewed like any other.
  """

  alias Avwe.Definition.Codec
  alias Avwe.{Repr, Space, Worldgen}

  @version 1
  @causes [:unknown]
  @breaks [:fuel, :dousing]
  @norms [:invited_fire]
  @item_kinds [:notebook]
  @components [:spring, :hearth]
  @set_keys %{spring: [:flow_m3_s, :temp_c], hearth: [:fuel_kg, :power_w]}

  @doc "The schema version this build reads and writes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The values a miracle may set on a `component` (`:spring` or `:hearth`)."
  @spec set_keys(atom()) :: [atom()]
  def set_keys(component), do: Map.get(@set_keys, component, [])

  @doc "The type of a whole definition file."
  @spec top() :: Codec.type()
  def top do
    {:map,
     [
       schema: {:where, :integer, &(&1 == @version), "the schema version #{@version}"},
       id: text(),
       name: text(),
       tagline: {:opt, {:nullable, :string}},
       description: {:opt, {:nullable, :string}},
       seed: :integer,
       dt: {:opt, {:where, :integer, &(&1 > 0), "a whole number above 0"}},
       start: :calendar_time,
       ruleset: {:opt, ruleset()},
       rules: {:opt, rules()},
       entities: {:opt, {:list, entity()}},
       miracles: {:opt, {:list, miracle()}},
       characters: {:opt, {:keyed, character()}},
       guests: {:opt, guests()}
     ]}
  end

  # A name or an id: not blank.
  defp text, do: {:where, :string, &(String.trim(&1) != ""), "a string that is not blank"}

  defp at_least(n), do: {:where, :number, &(&1 >= n), "a number, #{n} or more"}
  defp above(n), do: {:where, :number, &(&1 > n), "a number above #{n}"}

  # The ruleset: a preset and what is changed in it, or a list of rules.
  defp ruleset do
    {:where,
     {:keyword,
      [
        preset: {:opt, text()},
        with: {:opt, {:list, text()}},
        without: {:opt, {:list, text()}},
        rules: {:opt, {:list, text()}}
      ]}, &ruleset?/1, "a preset (with rules added or left out) or a list of rules, not both"}
  end

  defp ruleset?(given) do
    case {Keyword.has_key?(given, :preset), Keyword.has_key?(given, :rules)} do
      {true, false} ->
        true

      {false, true} ->
        not Keyword.has_key?(given, :with) and not Keyword.has_key?(given, :without)

      _both_or_neither ->
        false
    end
  end

  # Rules

  defp rules do
    {:map,
     [
       "earthlike.valley": {:opt, valley()},
       "earthlike.fire": {:opt, {:keyword, [hearths: {:opt, {:list, hearth()}}]}},
       "earthlike.weather": {:opt, {:keyword, [wind: {:opt, wind()}]}}
     ]}
  end

  defp valley do
    {:keyword,
     [
       river: {:opt, river()},
       rises: {:opt, {:list, {:place_entry, [height_m: :number, radius_cells: radius()]}}},
       clay: {:opt, {:list, {:place_entry, [radius_cells: radius()]}}}
     ]}
  end

  defp radius, do: {:where, :integer, &(&1 > 0), "a whole number of cells above 0"}

  defp river do
    {:keyword,
     [
       name: text(),
       flow_m3_s: {:where, :float, &(&1 >= 0.0), "a flow in m3/s, 0 or more"},
       water_c: :float,
       source: source(),
       through:
         {:where, {:list, :waypoint}, &(&1 != []),
          "a list of places to flow through, at least one"},
       exit: {:atom, Codec.directions()}
     ]}
  end

  defp source do
    {:keyword,
     [
       id: text(),
       name: text(),
       description: {:opt, {:nullable, :string}},
       from: :string,
       bearing: :range,
       cells: :range
     ]}
  end

  defp hearth do
    {:keyword, [id: text(), at: :string, name: text(), fuel_kg: at_least(0), power_w: above(0)]}
  end

  defp wind do
    directions = Space.directions()

    {:keyword,
     [
       from:
         {:opt,
          {:where, :string, &(&1 in directions),
           "a compass direction (#{Enum.join(directions, ", ")})"}},
       m_s: {:opt, at_least(0)}
     ]}
  end

  # Entities

  defp entity do
    {:map,
     [
       id: text(),
       place: {:opt, {:map, [label: :string]}},
       position: {:opt, :cell},
       repr: {:opt, {:map, [name: :string, description: {:nullable, :string}]}},
       article: {:opt, {:nullable, :string}},
       body: {:opt, {:map, [species: {:nullable, :string}]}},
       knows: {:opt, {:set, :string}},
       home: {:opt, :string}
     ]}
  end

  # Miracles

  defp miracle, do: {:tagged, :kind, event: event(), standing: standing()}

  defp event do
    {:keyword,
     [
       kind: {:atom, [:event]},
       id: text(),
       at: :calendar_time,
       target: text(),
       component: {:atom, @components},
       set:
         {:where, {:atom_map, @set_keys |> Map.values() |> List.flatten(), :float},
          &(map_size(&1) > 0), "at least one value to set"},
       cause: {:opt, {:atom, @causes}},
       note: {:opt, {:nullable, :string}}
     ]}
  end

  defp standing do
    {:keyword,
     [
       kind: {:atom, [:standing]},
       id: text(),
       name: text(),
       description: {:opt, {:nullable, :string}},
       at: :string,
       heat_w: above(0),
       breaks: {:opt, {:atoms, @breaks}},
       cause: {:opt, {:atom, @causes}},
       note: {:opt, {:nullable, :string}}
     ]}
  end

  # Characters

  defp character do
    {:keyword,
     [
       norms: {:opt, {:atoms, @norms}},
       carries: {:opt, {:list, item()}},
       routine: {:opt, {:list, routine_entry()}},
       glyph: {:opt, {:where, :string, &Repr.valid_char?/1, "one printable character"}},
       color: {:opt, {:where, :string, &Repr.valid_color?/1, "a colour like \"#aa8800\""}}
     ]}
  end

  defp item do
    {:keyword,
     [
       id: text(),
       kind: {:atom, @item_kinds},
       name: text(),
       description: {:opt, {:nullable, :string}}
     ]}
  end

  defp routine_entry do
    {:keyword,
     [
       at:
         {:where, :string, &match?({:ok, _seconds}, Worldgen.time_of_day(&1)),
          "a time of day like \"04:30\""},
       do: :plan,
       note: {:opt, {:nullable, :string}}
     ]}
  end

  defp guests do
    {:keyword, [arrival: text(), max: {:where, :integer, &(&1 > 0), "a whole number above 0"}]}
  end
end
