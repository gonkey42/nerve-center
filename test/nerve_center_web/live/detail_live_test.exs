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

    assert html =~ "KITT / Pi-hole"
    assert html =~ "Health State"
  end

  test "source detail renders for the daisy websocket source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_web_socket")

    assert html =~ "DAISY / Home Assistant Stream"
    assert html =~ "Health State"
  end

  test "source detail renders for the stig unifi source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/stig/unifi")

    assert html =~ "Stig / UniFi"
    assert html =~ "Health State"
  end

  test "source detail renders for the zoidberg glances source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/zoidberg/glances")

    assert html =~ "Zoidberg / Glances"
    assert html =~ "Health State"
  end

  test "dashboard and source list use friendly source names", %{conn: conn} do
    {:ok, _dashboard, dashboard_html} = live(conn, ~p"/")
    {:ok, _sources, sources_html} = live(conn, ~p"/sources")

    assert dashboard_html =~ "Local Metrics: "
    refute dashboard_html =~ ">local_metrics: "

    assert sources_html =~ "Home Assistant REST"
    assert sources_html =~ "Home Assistant Stream"
    assert sources_html =~ "Frigate Preview"
    refute sources_html =~ ">ha_rest_probe<"
    refute sources_html =~ ">ha_web_socket<"
    refute sources_html =~ ">frigate_preview<"
  end

  test "device detail uses friendly source names and hides raw module names", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/hal9000")

    assert html =~ "Local Metrics"
    assert html =~ "Launch Agents"
    refute html =~ ">local_metrics<"
    refute html =~ "NerveCenter.Sources.HAL9000.LocalMetricsSource"
  end
end
