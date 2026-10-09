defmodule Avwe.SystemTableTest do
  @moduledoc """
  The table of system ids is global to the VM. The tests that change what a shipped
  id means run by themselves (a module that is not async runs when the async ones
  are done) and put it back.
  """

  use ExUnit.Case, async: false

  alias Avwe.SystemTable

  @fire "earthlike.fire/step"

  setup do
    on_exit(fn -> SystemTable.put(@fire, Avwe.Systems.Fire) end)
  end

  test "an id of a rule the engine ships is found even when the table was never told of it" do
    :persistent_term.erase({SystemTable, @fire})

    assert SystemTable.fetch(@fire) == {:ok, Avwe.Systems.Fire}

    assert SystemTable.missing([@fire, "test.table.never/step"]) == ["test.table.never/step"]
  end

  test "looking for an id nothing runs does not undo a move of one that something does" do
    :ok = SystemTable.put(@fire, Avwe.Systems.Smoke)

    assert SystemTable.fetch("test.table.nobody/step") == :error
    assert SystemTable.fetch(@fire) == {:ok, Avwe.Systems.Smoke}
  end

  test "put_new says that a module runs a system only when none does" do
    :ok = SystemTable.put_new("test.table.fresh/step", Avwe.Systems.Fire)
    :ok = SystemTable.put_new("test.table.fresh/step", Avwe.Systems.Smoke)

    assert SystemTable.fetch("test.table.fresh/step") == {:ok, Avwe.Systems.Fire}

    :persistent_term.erase({SystemTable, "test.table.fresh/step"})
  end
end
