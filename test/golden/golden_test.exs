defmodule Avwe.GoldenTest do
  @moduledoc """
  The golden journal (`Avwe.Test.Golden`): the Ember Reach's recorded runs must
  come out the same, event for event and percept for percept, after any change
  that is meant to leave the world as it was. A failure here is a change of
  behaviour to be understood, not a record to be made again.
  """

  use ExUnit.Case, async: true

  alias Avwe.Test.Golden

  # A run takes several seconds, and the two do not share anything.
  @moduletag timeout: 120_000

  for name <- Golden.scenarios() do
    test "#{name} comes out as recorded" do
      assert Golden.differences(unquote(name), Golden.run(unquote(name))) == []
    end
  end
end
