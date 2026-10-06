defmodule Avwe.SpaceTest do
  use ExUnit.Case, async: true

  alias Avwe.Space

  test "directions follow the compass, with y growing to the south" do
    assert Space.direction({0, 0}, {0, -5}) == "north"
    assert Space.direction({0, 0}, {5, -5}) == "north-east"
    assert Space.direction({0, 0}, {5, 0}) == "east"
    assert Space.direction({0, 0}, {0, 5}) == "south"
    assert Space.direction({0, 0}, {-5, 5}) == "south-west"
    assert Space.direction({3, 3}, {3, 3}) == nil
  end

  test "the Ember Reach's places, as seen from the town" do
    town = {121, 138}
    assert Space.direction(town, {163, 78}) == "north-east"
    assert Space.meters(Space.distance(town, {163, 78})) == 730
    assert Space.direction(town, {94, 105}) == "north-west"
    assert Space.direction(town, {138, 162}) == "south-east"
  end

  test "lerp moves part of the way between cells" do
    assert Space.lerp({0, 0}, {10, 20}, 0.5) == {5, 10}
    assert Space.lerp({0, 0}, {10, 20}, 1.0) == {10, 20}
  end
end
