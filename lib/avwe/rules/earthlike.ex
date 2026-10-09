defmodule Avwe.Rules.Earthlike do
  @moduledoc """
  The Earth-like physics as a package of rules, one for each system and one for
  the ground: daylight, weather, a river, fire, the heat of the ground and the
  air, smoke, and the valley they sit in. The preset `"earthlike"` is these and
  `play`.

  Each rule says what it owns, provides and needs (`Avwe.Rule`), as the six
  direct calls between the systems are today: the river and the heat call the
  weather, the heat calls the daylight, the fire and the river, smoke calls the
  fire. The systems still call each other by module name; saying it here makes
  the check refuse a ruleset that leaves one out, and E3 to E5 route the calls
  through the capabilities.
  """

  @behaviour Avwe.RulePackage

  @impl Avwe.RulePackage
  def rules do
    [
      Avwe.Rules.Earthlike.Daylight,
      Avwe.Rules.Earthlike.Weather,
      Avwe.Rules.Earthlike.Valley,
      Avwe.Rules.Earthlike.River,
      Avwe.Rules.Earthlike.Fire,
      Avwe.Rules.Earthlike.Heat,
      Avwe.Rules.Earthlike.Smoke
    ]
  end

  @impl Avwe.RulePackage
  def presets do
    %{
      "earthlike" => [
        "play",
        "earthlike.daylight",
        "earthlike.weather",
        "earthlike.valley",
        "earthlike.river",
        "earthlike.fire",
        "earthlike.heat",
        "earthlike.smoke"
      ]
    }
  end
end
