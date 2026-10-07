defmodule AvweWeb.PagesTest do
  use ExUnit.Case, async: false

  import Avwe.Test.Fixtures, only: [eventually: 1]

  alias AvweWeb.Pages

  # The registry is shared by every test, and the pages of one test are still
  # being cleared out of it as the next begins, so each test has browsers of its
  # own: whatever another test's pages left behind is somebody else's.
  setup do
    unique = System.unique_integer([:positive])
    %{mine: "mine-#{unique}", yours: "yours-#{unique}", theirs: "theirs-#{unique}"}
  end

  # A page: a process that registers what it holds, and tells the test when it
  # is asked to let go. It can be told to let go of what it holds, or to end.
  defp page(world, body, browser) do
    test = self()

    pid =
      spawn_link(fn ->
        Pages.register(world, body, browser)
        send(test, {:holding, self()})
        hold(test, world, body)
      end)

    assert_receive {:holding, ^pid}, 1_000
    pid
  end

  defp hold(test, world, body) do
    receive do
      :let_go ->
        send(test, {:asked, self()})
        hold(test, world, body)

      :release ->
        Pages.release(world, body)
        send(test, {:released, self()})
        hold(test, world, body)

      :end ->
        :ok
    end
  end

  describe "what a browser's pages hold" do
    test "is what they registered, and not what another browser's pages hold", %{
      mine: mine,
      yours: yours
    } do
      page(:pages_a, "wren", mine)
      page(:pages_a, "pell", mine)
      page(:pages_b, "wren", yours)

      assert Pages.held_by(mine) == [{:pages_a, "pell"}, {:pages_a, "wren"}]
      assert Pages.held_by(yours) == [{:pages_b, "wren"}]
      assert Pages.held_by("nobody's") == []
    end

    test "ends when the page lets go", %{mine: mine} do
      page = page(:pages_a, "wren", mine)
      assert Pages.held_by(mine) == [{:pages_a, "wren"}]

      send(page, :release)
      assert_receive {:released, ^page}, 1_000

      assert Pages.held_by(mine) == []
    end

    test "ends when the page does", %{mine: mine} do
      page = page(:pages_a, "wren", mine)
      monitor = Process.monitor(page)

      send(page, :end)
      assert_receive {:DOWN, ^monitor, :process, ^page, _reason}, 1_000

      assert eventually(fn -> Pages.held_by(mine) == [] end)
    end

    test "is nothing for a page that has no browser to name" do
      page(:pages_a, "wren", nil)

      assert Pages.held_by(nil) == []
    end
  end

  describe "asking the pages of a browser to let go" do
    test "reaches the pages of that browser that hold the body, and no others", %{
      mine: mine,
      theirs: theirs
    } do
      held = page(:pages_a, "wren", mine)
      other_body = page(:pages_a, "pell", mine)
      other_browser = page(:pages_a, "wren", theirs)

      assert Pages.ask_to_let_go(:pages_a, "wren", mine) == :ok

      assert_receive {:asked, ^held}, 1_000
      # Another body of the same browser, and the same body of another browser.
      refute_receive {:asked, ^other_body}, 50
      refute_receive {:asked, ^other_browser}, 50
    end

    test "does not reach another world's body of the same name", %{mine: mine} do
      elsewhere = page(:pages_b, "wren", mine)

      Pages.ask_to_let_go(:pages_a, "wren", mine)

      refute_receive {:asked, ^elsewhere}, 50
    end

    test "never reaches the one who asks", %{mine: mine} do
      Pages.register(:pages_a, "wren", mine)

      Pages.ask_to_let_go(:pages_a, "wren", mine)

      refute_receive :let_go, 50
      Pages.release(:pages_a, "wren")
    end

    test "reaches nobody for a browser that has no name, even a page that has none either" do
      nameless = page(:pages_a, "wren", nil)

      assert Pages.ask_to_let_go(:pages_a, "wren", nil) == :ok

      refute_receive {:asked, ^nameless}, 50
    end

    test "reaches nobody for a body nobody holds", %{mine: mine} do
      assert Pages.ask_to_let_go(:pages_a, "nobody", mine) == :ok
    end
  end
end
