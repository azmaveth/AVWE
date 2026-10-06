defmodule Avwe.MCP.StepsTest do
  use ExUnit.Case, async: true

  alias Avwe.MCP.Steps

  @look %{
    here: %{id: "hollow-green", name: "Hollow Green"},
    places: [%{id: "mill-pond", name: "Mill Pond"}, %{id: "mill-race", name: "Mill Race"}],
    hearths: [%{id: "fire-pit", name: "the fire pit"}],
    carried: [%{id: "wren-notebook", name: "field notebook"}]
  }

  test "one step from verb, target and params, names matched against the look" do
    assert {:ok, [{:go, [target: "mill-pond", params: %{}]}]} =
             Steps.parse(%{"verb" => "go", "target" => "the mill pond"}, @look)

    assert {:ok, [{:kindle, [target: "fire-pit", params: %{}]}]} =
             Steps.parse(%{"verb" => "Kindle", "target" => "fire pit"}, @look)

    assert {:ok, [{:kindle, [params: %{}]}]} = Steps.parse(%{"verb" => "kindle"}, @look)
  end

  test "a name that matches nothing is passed on for the world to refuse" do
    assert {:ok, [{:go, [target: "atlantis", params: %{}]}]} =
             Steps.parse(%{"verb" => "go", "target" => "atlantis"}, @look)
  end

  test "parameters become what the world takes, atoms only from fixed lists" do
    assert {:ok, [{:say, [params: %{text: "Hi", volume: :shout}]}]} =
             Steps.parse(
               %{"verb" => "say", "params" => %{"text" => "Hi", "volume" => "SHOUT"}},
               @look
             )

    assert {:ok, [{:say, [params: %{volume: "bellow"}]}]} =
             Steps.parse(%{"verb" => "say", "params" => %{"volume" => "bellow"}}, @look)

    assert {:ok, [{:wait, [params: %{for: 1_200}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"minutes" => 20}}, @look)

    assert {:ok, [{:wait, [params: %{until: :dusk}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"until" => "sunset"}}, @look)

    assert {:ok, [{:walk, [params: %{direction: "north-east", distance_m: 300}]}]} =
             Steps.parse(
               %{"verb" => "walk", "params" => %{"direction" => "NE", "distance_m" => 300}},
               @look
             )

    assert {:ok, [{:follow, [params: %{direction: :upstream}]}]} =
             Steps.parse(%{"verb" => "follow", "target" => "upstream"}, @look)

    assert {:ok, [{:read, [target: "wren-notebook", params: %{last: 3}]}]} =
             Steps.parse(
               %{"verb" => "read", "target" => "field notebook", "params" => %{"last" => 3}},
               @look
             )
  end

  test "a plan, in order" do
    steps = [
      %{"verb" => "go", "target" => "Mill Pond"},
      %{"verb" => "write", "params" => %{"text" => "Low."}}
    ]

    assert {:ok, [{:go, [target: "mill-pond", params: %{}]}, {:write, [params: %{text: "Low."}]}]} =
             Steps.parse(%{"steps" => steps}, @look)
  end

  test "what can't be a plan is refused in plain words" do
    assert {:error, "Unknown verb \"dance\"." <> _} = Steps.parse(%{"verb" => "dance"}, @look)

    assert {:error, "Which do you mean: Mill Pond, Mill Race?"} =
             Steps.parse(%{"verb" => "go", "target" => "mill"}, @look)

    assert {:error, "go needs a target" <> _} = Steps.parse(%{"verb" => "go"}, @look)
    assert {:error, "wait needs params" <> _} = Steps.parse(%{"verb" => "wait"}, @look)

    assert {:error, "Step 2: Unknown verb" <> _} =
             Steps.parse(%{"steps" => [%{"verb" => "stop"}, %{"verb" => "fly"}]}, @look)

    assert {:error, "The list of steps is empty."} = Steps.parse(%{"steps" => []}, @look)

    assert {:error, "Give either a verb" <> _} =
             Steps.parse(%{"verb" => "stop", "steps" => [%{"verb" => "stop"}]}, @look)

    assert {:error, "Give a verb" <> _} = Steps.parse(%{}, @look)

    assert {:error, "params must be an object."} =
             Steps.parse(%{"verb" => "say", "params" => "hi"}, @look)
  end
end
