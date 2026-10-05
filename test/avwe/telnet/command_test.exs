defmodule Avwe.Telnet.CommandTest do
  use ExUnit.Case, async: true

  alias Avwe.Telnet.Command

  doctest Avwe.Telnet.Command

  describe "parse/1" do
    test "looking, going, stopping and leaving" do
      assert Command.parse("look") == :look
      assert Command.parse("L") == :look
      assert Command.parse("walk Willow Docks") == {:go, "Willow Docks"}
      assert Command.parse("go") == {:invalid, "Go where?"}
      assert Command.parse("stop") == :stop
      assert Command.parse("time") == :time
      assert Command.parse("?") == :help
      assert Command.parse("exit") == :quit
      assert Command.parse("   ") == :empty
    end

    test "speaking at three volumes" do
      assert Command.parse("say Hello, Tamsin.") == {:say, :talk, "Hello, Tamsin."}
      assert Command.parse("whisper psst") == {:say, :whisper, "psst"}
      assert Command.parse("SHOUT fire!") == {:say, :shout, "fire!"}
      assert Command.parse("say") == {:invalid, "Say what?"}
      assert Command.parse("whisper") == {:invalid, "Whisper what?"}
    end

    test "waiting" do
      assert Command.parse("wait") == {:wait, %{for: 600}}
      assert Command.parse("wait 30") == {:wait, %{for: 1_800}}
      assert Command.parse("wait 2 hours") == {:wait, %{for: 7_200}}
      assert Command.parse("wait for 45 minutes") == {:wait, %{for: 2_700}}
      assert Command.parse("wait until dusk") == {:wait, %{until: :dusk}}
      assert Command.parse("wait till sunrise") == {:wait, %{until: :dawn}}
      assert {:invalid, "Wait how long?" <> _rest} = Command.parse("wait forever")
      assert {:invalid, _message} = Command.parse("wait 0")
    end

    test "following the channel and walking in a direction" do
      assert Command.parse("follow the channel upstream") == {:follow, :upstream}
      assert Command.parse("follow river down") == {:follow, :downstream}
      assert Command.parse("go upstream") == {:follow, :upstream}
      assert Command.parse("follow") == {:invalid, "Follow the channel upstream or downstream?"}
      assert Command.parse("go north") == {:walk, "north", 100}
      assert Command.parse("walk NE 250") == {:walk, "north-east", 250}
      assert Command.parse("go south-west 40 m") == {:walk, "south-west", 40}
      assert Command.parse("go docks") == {:go, "docks"}
      assert Command.parse("go west rise") == {:go, "west rise"}
    end

    test "lighting and dousing the fire" do
      assert Command.parse("kindle") == :kindle
      assert Command.parse("light") == :kindle
      assert Command.parse("light the fire") == :kindle
      assert Command.parse("Light fire") == :kindle
      assert Command.parse("light the hearth") == :kindle
      assert Command.parse("douse") == :douse
      assert Command.parse("douse the fire") == :douse
      assert Command.parse("put out the fire") == :douse
      assert Command.parse("put out") == :douse
      assert Command.parse("light a candle") == {:unknown, "light a candle"}
      assert Command.parse("put on a hat") == {:unknown, "put on a hat"}
    end

    test "anything else is unknown" do
      assert Command.parse("dance wildly") == {:unknown, "dance wildly"}
    end
  end

  describe "resolve/2" do
    @places [
      {"the-dry-bend", "The Dry Bend"},
      {"willow-docks", "Willow Docks"},
      {"ember-reach", "Ember Reach"}
    ]

    test "ignores case and a leading 'the'" do
      assert Command.resolve("THE DRY BEND", @places) == {:ok, "the-dry-bend"}
      assert Command.resolve("docks", @places) == {:ok, "willow-docks"}
      assert Command.resolve("ember-reach", @places) == {:ok, "ember-reach"}
    end

    test "reports ambiguity and misses" do
      assert Command.resolve("e", @places) == {:ambiguous, ["The Dry Bend", "Ember Reach"]}
      assert Command.resolve("atlantis", @places) == :none
    end

    test "prefers an exact match over partial ones" do
      assert Command.resolve("mill", [{"mill", "Mill"}, {"mill-pond", "Mill Pond"}]) ==
               {:ok, "mill"}
    end
  end
end
