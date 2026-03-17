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

  test "device detail renders for rosie", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/rosie")

    assert html =~ "ROSIE"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for daisy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/daisy")

    assert html =~ "DAISY"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for stig", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/stig")

    assert html =~ "Stig"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for zoidberg", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/zoidberg")

    assert html =~ "Zoidberg"
    assert html =~ "Current Metrics"
  end

  test "source detail renders for the kitt pihole source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/kitt/pihole")

    assert html =~ "KITT / pihole"
    assert html =~ "Health State"
  end

  test "source detail renders for the daisy websocket source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_web_socket")

    assert html =~ "DAISY / ha_web_socket"
    assert html =~ "Health State"
  end

  test "source detail renders for the stig unifi source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/stig/unifi")

    assert html =~ "Stig / unifi"
    assert html =~ "Health State"
  end

  test "source detail renders for the zoidberg glances source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/zoidberg/glances")

    assert html =~ "Zoidberg / glances"
    assert html =~ "Health State"
  end
end
