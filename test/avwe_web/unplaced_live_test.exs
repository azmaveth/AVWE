defmodule AvweWeb.UnplacedLiveTest do
  @moduledoc """
  The pages of a world with characters that are nowhere (their homes are not
  pins on the map): Lantern Hollow with Brine, whose home is an article and not
  a pin, and Moth, who has none. The lobby offers only those who can be played,
  and a page asked for one of the others says why and sends the player back.
  """

  use Avwe.Test.WebCase, async: false

  @world :hollow_unplaced_web
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {:ok, _pid} =
      Avwe.start_world(@world, quire: hollow_with_wanderers(dir), start: {1, hour: 12})

    on_exit(fn -> Avwe.stop_world(@world) end)
    :ok
  end

  test "the lobby offers the bodies that can be played, and not the ones that are nowhere",
       %{conn: conn} do
    {:ok, lobby, html} = live(conn, ~p"/")

    assert html =~ "Wren"
    assert html =~ "Odo"
    refute html =~ "Brine"
    refute html =~ "Moth"
    assert has_element?(lobby, "li.body", "Wren")
  end

  test "a page asked for one says why, and the player is sent back to the lobby", %{conn: conn} do
    {:ok, lobby, html} =
      conn |> live(~p"/play/hollow_unplaced_web/brine") |> follow_redirect(conn, ~p"/")

    message = "Brine lives somewhere the map does not show, so nobody can play them yet."
    assert html =~ message
    assert has_element?(lobby, ".notice.error", message)
    assert Registry.lookup(Avwe.Registry, {:lease, @world, "brine"}) == []
  end

  test "a page asked for someone who does not exist still says so", %{conn: conn} do
    {:ok, _lobby, html} =
      conn |> live(~p"/play/hollow_unplaced_web/ghost") |> follow_redirect(conn, ~p"/")

    assert html =~ "There is nobody by that name in Lantern Hollow."
  end

  test "a page for a body that can be played still opens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/play/hollow_unplaced_web/wren")
    assert render(view) =~ "Wren"
  end
end
