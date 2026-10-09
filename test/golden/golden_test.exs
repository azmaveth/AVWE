defmodule Avwe.GoldenTest do
  @moduledoc """
  The golden journal (`Avwe.Test.Golden`): the Ember Reach's recorded runs must
  come out the same, event for event and percept for percept, after any change
  that is meant to leave the world as it was. A failure here is a change of
  behaviour to be understood, not a record to be made again.

  Each is run twice, once from the region Quire and the world's settings build
  (the way the record was made) and once from the world's definition (the way
  a world runs): the new path is the old world.
  """

  use ExUnit.Case, async: true

  alias Avwe.Test.Golden

  # A run takes several seconds, and the two do not share anything.
  @moduletag timeout: 120_000

  for name <- Golden.scenarios(), source <- [:quire, :definition] do
    test "#{name}, from #{source}, comes out as recorded" do
      assert Golden.differences(unquote(name), Golden.run(unquote(name), unquote(source))) == []
    end
  end
end
