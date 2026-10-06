defmodule AvweWeb.HudTest do
  use ExUnit.Case, async: true

  alias Avwe.{Perception, Region}
  alias Avwe.Test.Ember
  alias AvweWeb.Hud

  @mira "mira-vale"

  defp look(region) do
    region
    |> Region.view()
    |> Map.put(:terrain, region.terrain)
    |> Perception.look(@mira)
  end

  defp noon, do: Ember.region({813, day: 220, hour: 12}) |> Ember.controlled()

  defp buttons(hud, title) do
    case Enum.find(hud.groups, &(&1.title == title)) do
      nil -> []
      group -> group.buttons
    end
  end

  defp lines(hud, title), do: hud |> buttons(title) |> Enum.map(& &1.line)

  describe "build/1" do
    test "says the time and the light as a look does" do
      hud = noon() |> look() |> Hud.build()

      assert hud.clock == "813 AR, day 220, 12:00. It is daylight."
    end

    test "offers the places the body knows, each with how far and which way" do
      hud = noon() |> look() |> Hud.build()

      assert %{label: "The Dry Bend (" <> _, line: "go to the-dry-bend"} =
               Enum.find(buttons(hud, "Places"), &(&1.line == "go to the-dry-bend"))

      assert Enum.any?(
               buttons(hud, "Places"),
               &(&1.label =~ ~r/^Willow Docks \(\d+ m [a-z-]+\)$/)
             )

      # Not the place it is at.
      refute "go to ember-reach" in lines(hud, "Places")
    end

    test "offers to light a cold hearth it stands by, and to put out one that burns" do
      region = noon()
      hud = region |> look() |> Hud.build()

      assert buttons(hud, "Fire") == [
               %{label: "Light the kiln-house hearth", line: "kindle town-hearth"}
             ]

      burning = %{Region.get(region, "town-hearth", :hearth) | burning: true}

      lit =
        region |> Region.put_component("town-hearth", :hearth, burning) |> look() |> Hud.build()

      assert buttons(lit, "Fire") == [
               %{label: "Put out the kiln-house hearth", line: "douse town-hearth"}
             ]
    end

    test "offers no fire to a body that is nowhere near one" do
      far = noon() |> Region.put_component(@mira, :position, {163, 78})
      hud = far |> look() |> Hud.build()

      assert buttons(hud, "Fire") == []
      refute Enum.any?(hud.groups, &(&1.title == "Fire"))
    end

    test "offers to wait, and to read a notebook it carries" do
      hud = noon() |> look() |> Hud.build()

      assert lines(hud, "Actions") == ["wait", "wait until dawn", "wait until dusk", "read"]
      assert %{label: "Wait"} = hd(buttons(hud, "Actions"))
    end

    test "offers to stop only when there is something to stop" do
      region = noon()
      refute "stop" in lines(Hud.build(look(region)), "Actions")

      going = %{ref: "i-1", verb: :go, target: "the-dry-bend", params: %{}, until: nil}
      busy = Region.put_component(region, @mira, :action, going)
      assert "stop" in lines(Hud.build(look(busy)), "Actions")
    end

    test "leaves out the groups that have nothing in them, and survives a look with no affordances" do
      bare = %{time: 0, light: 1.0, places: [], hearths: []}

      assert Hud.build(bare).groups == []

      assert Hud.build(Map.put(bare, :affordances, [%{verb: :go, targets: ["nowhere"]}])).groups ==
               []

      # Nor a button for a hearth that the look does not name.
      ghost = [%{verb: :kindle, targets: ["ghost-hearth"]}, %{verb: :douse, targets: ["another"]}]
      assert Hud.build(Map.put(bare, :affordances, ghost)).groups == []
    end

    test "every button is a line the command parser understands as an act or a reading" do
      region = noon()
      burning = %{Region.get(region, "town-hearth", :hearth) | burning: true}
      going = %{ref: "i-1", verb: :go, target: "the-dry-bend", params: %{}, until: nil}

      for region <- [
            region,
            Region.put_component(region, "town-hearth", :hearth, burning),
            Region.put_component(region, @mira, :action, going)
          ],
          look = look(region),
          group <- Hud.build(look).groups,
          button <- group.buttons do
        command = Avwe.Command.parse(button.line)
        assert match?({:act, _verb, _opts}, Avwe.Command.interpret(command, look)), button.line
      end
    end
  end
end
