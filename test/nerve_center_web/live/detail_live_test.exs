defmodule NerveCenterWeb.DetailLiveTest do
  use NerveCenterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "device detail renders for phase 1 devices", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/hal9000")

    assert html =~ "HAL9000"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for ups", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/ups")

    assert html =~ "UPS"
    assert html =~ "Current Metrics"
  end

  test "source detail renders for the kitt pihole source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/kitt/pihole")

    assert html =~ "KITT / pihole"
    assert html =~ "Health State"
  end
end
