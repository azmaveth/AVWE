defmodule Avwe.MCP.StepsTest do
  use ExUnit.Case, async: true

  alias Avwe.MCP.Steps

  test "one step from verb, target and params; targets are names for the Mind to resolve" do
    assert {:ok, [{:go, [target_name: "the mill pond", params: %{}]}]} =
             Steps.parse(%{"verb" => "go", "target" => "the mill pond"})

    assert {:ok, [{:kindle, [target_name: "fire pit", params: %{}]}]} =
             Steps.parse(%{"verb" => "Kindle", "target" => "fire pit"})

    assert {:ok, [{:kindle, [params: %{}]}]} = Steps.parse(%{"verb" => "kindle"})
  end

  test "a target must be a name" do
    assert {:error, "The place must be named with a string."} =
             Steps.parse(%{"verb" => "go", "target" => 7})

    assert {:error, "The hearth must be named with a string."} =
             Steps.parse(%{"verb" => "douse", "target" => ["x"]})
  end

  test "parameters become what the world takes, atoms only from fixed lists" do
    assert {:ok, [{:say, [params: %{text: "Hi", volume: :shout}]}]} =
             Steps.parse(%{"verb" => "say", "params" => %{"text" => "Hi", "volume" => "SHOUT"}})

    assert {:ok, [{:say, [params: %{volume: "bellow"}]}]} =
             Steps.parse(%{"verb" => "say", "params" => %{"volume" => "bellow"}})

    assert {:ok, [{:wait, [params: %{for: 1_200}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"minutes" => 20}})

    assert {:ok, [{:wait, [params: %{until: :dusk}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"until" => "sunset"}})

    assert {:ok, [{:walk, [params: %{direction: "north-east", distance_m: 300}]}]} =
             Steps.parse(%{
               "verb" => "walk",
               "params" => %{"direction" => "NE", "distance_m" => 300}
             })

    assert {:ok, [{:follow, [params: %{direction: :upstream}]}]} =
             Steps.parse(%{"verb" => "follow", "target" => "upstream"})

    assert {:ok, [{:read, [target_name: "field notebook", params: %{last: 3}]}]} =
             Steps.parse(%{
               "verb" => "read",
               "target" => "field notebook",
               "params" => %{"last" => 3}
             })
  end

  test "a plan, in order" do
    steps = [
      %{"verb" => "go", "target" => "Mill Pond"},
      %{"verb" => "write", "params" => %{"text" => "Low."}}
    ]

    assert {:ok,
            [{:go, [target_name: "Mill Pond", params: %{}]}, {:write, [params: %{text: "Low."}]}]} =
             Steps.parse(%{"steps" => steps})
  end

  test "what can't be a plan is refused in plain words" do
    assert {:error, "Unknown verb \"dance\"." <> _} = Steps.parse(%{"verb" => "dance"})

    assert {:error, "go needs a target" <> _} = Steps.parse(%{"verb" => "go"})
    assert {:error, "wait needs params" <> _} = Steps.parse(%{"verb" => "wait"})

    assert {:error, "Step 2: Unknown verb" <> _} =
             Steps.parse(%{"steps" => [%{"verb" => "stop"}, %{"verb" => "fly"}]})

    assert {:error, "The list of steps is empty."} = Steps.parse(%{"steps" => []})

    assert {:error, "Give either a verb" <> _} =
             Steps.parse(%{"verb" => "stop", "steps" => [%{"verb" => "stop"}]})

    assert {:error, "Give a verb" <> _} = Steps.parse(%{})

    assert {:error, "params must be an object."} =
             Steps.parse(%{"verb" => "say", "params" => "hi"})
  end
end
