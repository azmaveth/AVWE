defmodule Avwe.CommandTest do
  use ExUnit.Case, async: true

  alias Avwe.Command

  doctest Avwe.Command

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

    test "writing and reading the notebook" do
      assert Command.parse("write  The reeds lean North. ") == {:write, "The reeds lean North."}
      assert Command.parse("WRITE x") == {:write, "x"}
      assert Command.parse("write") == {:invalid, "Write what?"}
      assert Command.parse("read") == {:read, nil}
      assert Command.parse("notes") == {:read, nil}
      assert Command.parse("read 5") == {:read, 5}
      assert Command.parse("read 0") == {:invalid, "Read how many pages? Try: read, read 5."}
      assert Command.parse("read all") == {:invalid, "Read how many pages? Try: read, read 5."}
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

    test "lighting and dousing the fire, bare or by a hearth's name" do
      assert Command.parse("kindle") == {:kindle, nil}
      assert Command.parse("light") == {:kindle, nil}
      assert Command.parse("light the fire") == {:kindle, nil}
      assert Command.parse("Light fire") == {:kindle, nil}
      assert Command.parse("light the hearth") == {:kindle, nil}
      assert Command.parse("douse") == {:douse, nil}
      assert Command.parse("douse the fire") == {:douse, nil}
      assert Command.parse("put out the fire") == {:douse, nil}
      assert Command.parse("put out") == {:douse, nil}

      assert Command.parse("light the lodge hearth") == {:kindle, "lodge hearth"}
      assert Command.parse("kindle Lodge Hearth") == {:kindle, "lodge hearth"}
      assert Command.parse("douse the coal") == {:douse, "coal"}

      assert Command.parse("put out the fire in the kiln-house hearth") ==
               {:douse, "kiln-house hearth"}

      assert Command.parse("put out the fire at the lodge hearth") == {:douse, "lodge hearth"}
      # A name that matches no hearth is the connection's to refuse.
      assert Command.parse("light a candle") == {:kindle, "a candle"}
      # Only whole words are stripped, and a bare article is no name.
      assert Command.parse("douse the fireplace") == {:douse, "fireplace"}
      assert Command.parse("douse the") == {:douse, nil}
      assert Command.parse("put out the fire in the lodge") == {:douse, "lodge"}
      assert Command.parse("put on a hat") == {:unknown, "put on a hat"}
      assert Command.parse("put the fire out") == {:unknown, "put the fire out"}
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

  describe "interpret/2" do
    @look %{
      spectator: false,
      here: %{id: "ember-reach", name: "Ember Reach"},
      places: [
        %{id: "the-dry-bend", name: "The Dry Bend"},
        %{id: "willow-docks", name: "Willow Docks"}
      ],
      hearths: [
        %{id: "kiln-hearth", name: "the kiln-house hearth"},
        %{id: "lodge-hearth", name: "the lodge hearth"}
      ]
    }

    defp interpret(line, look \\ @look), do: line |> Command.parse() |> Command.interpret(look)

    test "what a client answers in its own way passes through, and an empty line is nothing" do
      assert interpret("look") == :look
      assert interpret("time") == :time
      assert interpret("help") == :help
      assert interpret("quit") == :quit
      assert interpret("   ") == :noop
    end

    test "an act carries its parameters as telnet has always sent them" do
      assert interpret("follow upstream") == {:act, :follow, params: %{direction: :upstream}}

      assert interpret("go north-east 200") ==
               {:act, :walk, params: %{direction: "north-east", distance_m: 200}}

      assert interpret("shout fire!") == {:act, :say, params: %{text: "fire!", volume: :shout}}
      assert interpret("wait until dawn") == {:act, :wait, params: %{until: :dawn}}
      assert interpret("wait 30") == {:act, :wait, params: %{for: 1_800}}

      assert interpret("write The reeds lean north.") ==
               {:act, :write, params: %{text: "The reeds lean north."}}

      assert interpret("read") == {:act, :read, params: %{}}
      assert interpret("read 3") == {:act, :read, params: %{last: 3}}
      assert interpret("stop") == {:act, :stop, []}
    end

    test "a place is resolved among those the body knows, and the one it is at" do
      assert interpret("go to the dry bend") == {:act, :go, target: "the-dry-bend"}
      assert interpret("go docks") == {:act, :go, target: "willow-docks"}
      assert interpret("go ember reach") == {:act, :go, target: "ember-reach"}
    end

    test "a place that matches nothing, or several things, is refused in words" do
      assert interpret("go atlantis") == {:error, ~s(You don't know a place called "atlantis".)}
      assert interpret("go d") == {:error, "Which do you mean: The Dry Bend, Willow Docks?"}

      assert interpret("go dry bend", nil) ==
               {:error, ~s(You don't know a place called "dry bend".)}
    end

    test "a hearth is resolved among those within reach; none named means the nearest" do
      assert interpret("kindle") == {:act, :kindle, []}
      assert interpret("light the fire") == {:act, :kindle, []}
      assert interpret("douse") == {:act, :douse, []}
      assert interpret("light the lodge hearth") == {:act, :kindle, target: "lodge-hearth"}

      assert interpret("put out the fire in the kiln-house hearth") ==
               {:act, :douse, target: "kiln-hearth"}
    end

    test "a hearth that matches nothing, or several things, is refused in words" do
      assert interpret("douse the coal") == {:error, ~s(There is no hearth called "coal" here.)}

      assert interpret("light the e hearth") ==
               {:error, "Which do you mean: the kiln-house hearth, the lodge hearth?"}
    end

    test "a spectator is refused a named hearth here; its other acts are the session's to refuse" do
      spectator = %{@look | spectator: true}

      assert interpret("light the lodge hearth", spectator) == {:error, "You're only watching."}
      assert interpret("kindle", spectator) == {:act, :kindle, []}

      assert interpret("say hello", spectator) ==
               {:act, :say, params: %{text: "hello", volume: :talk}}
    end

    test "what could not be understood is a refusal, in the words telnet uses" do
      assert interpret("go") == {:error, "Go where?"}
      assert interpret("say") == {:error, "Say what?"}

      assert interpret("dance wildly") ==
               {:error, ~s(I don't understand "dance wildly". Type help for a list of commands.)}
    end
  end

  describe "needs_look?/1" do
    test "only a place, or a named hearth, is resolved against the look" do
      assert Command.needs_look?({:go, "the dry bend"})
      assert Command.needs_look?({:kindle, "lodge hearth"})
      assert Command.needs_look?({:douse, "the coal"})

      refute Command.needs_look?({:kindle, nil})
      refute Command.needs_look?({:say, :talk, "hi"})
      refute Command.needs_look?(:look)
      refute Command.needs_look?(:stop)
    end

    test "every command that does not need the look can be interpreted without one" do
      lines =
        ~w(look time help quit stop kindle douse wait read) ++
          ["write x", "say hi", "follow up", "go north 100", "", "dance"]

      for line <- lines do
        command = Command.parse(line)
        refute Command.needs_look?(command), line
        assert Command.interpret(command, nil), line
      end
    end
  end
end
