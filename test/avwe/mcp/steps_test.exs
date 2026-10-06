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

    assert {:error, "wait needs one of: minutes, hours, for (seconds) or until" <> _} =
             Steps.parse(%{"verb" => "wait"})

    assert {:error, "Step 2: Unknown verb" <> _} =
             Steps.parse(%{"steps" => [%{"verb" => "stop"}, %{"verb" => "fly"}]})

    assert {:error, "The list of steps is empty."} = Steps.parse(%{"steps" => []})

    assert {:error, "Give either a verb" <> _} =
             Steps.parse(%{"verb" => "stop", "steps" => [%{"verb" => "stop"}]})

    assert {:error, "Give a verb" <> _} = Steps.parse(%{})

    assert {:error, "params must be an object."} =
             Steps.parse(%{"verb" => "say", "params" => "hi"})
  end

  test "what the world would refuse is refused first, in plain words, naming the problem" do
    refused = fn args ->
      assert {:error, message} = Steps.parse(args)
      message
    end

    assert refused.(%{"verb" => "say"}) == "say needs text: what to say."
    assert refused.(%{"verb" => "say", "params" => %{"text" => "  "}}) =~ "say needs text"

    assert refused.(%{"verb" => "write", "params" => %{}}) ==
             "write needs text: the page to write."

    assert refused.(%{"verb" => "say", "params" => %{"text" => 7}}) ==
             "The text must be a string."

    assert refused.(%{"verb" => "say", "params" => %{"text" => String.duplicate("a", 501)}}) ==
             "The text is too long: at most 500 characters."

    assert refused.(%{"verb" => "say", "params" => %{"text" => "Hi", "volume" => "bellow"}}) ==
             ~s(volume must be whisper, talk or shout, not "bellow".)

    assert refused.(%{"verb" => "wait", "params" => %{"until" => "noon"}}) ==
             ~s(until must be dawn or dusk, not "noon".)

    assert refused.(%{"verb" => "follow", "params" => %{"direction" => "north"}}) ==
             ~s(direction must be upstream or downstream, not "north".)

    assert refused.(%{"verb" => "follow"}) == "follow needs a direction: upstream or downstream."

    assert refused.(%{"verb" => "wait", "params" => %{"minutes" => 5, "until" => "dusk"}}) ==
             "wait takes one of minutes, hours, for or until, not minutes and until together."

    assert refused.(%{"verb" => "wait", "params" => %{"for" => 30}}) ==
             "A wait lasts at least a minute (for: 30)."

    assert refused.(%{"verb" => "wait", "params" => %{"hours" => 200}}) ==
             "A wait lasts at most a week (hours: 200)."

    assert refused.(%{"verb" => "wait", "params" => %{"minutes" => "ten"}}) ==
             ~s(minutes must be a number, not "ten".)

    assert refused.(%{"verb" => "read", "params" => %{"last" => 0}}) ==
             "last must be a whole number of pages from 1 to 50."

    assert refused.(%{"steps" => List.duplicate(%{"verb" => "stop"}, 51)}) =~
             "A plan has at most 50 steps; this one has 51."

    assert refused.(%{"steps" => [%{"verb" => "stop"}, %{"verb" => "say"}]}) ==
             "Step 2: say needs text: what to say."
  end

  test "a wait in hours, or exactly a minute, passes" do
    assert {:ok, [{:wait, [params: %{for: 5_400}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"hours" => 1.5}})

    assert {:ok, [{:wait, [params: %{for: 60}]}]} =
             Steps.parse(%{"verb" => "wait", "params" => %{"minutes" => 1}})

    assert {:ok, steps} = Steps.parse(%{"steps" => List.duplicate(%{"verb" => "stop"}, 50)})
    assert length(steps) == 50
  end
end
