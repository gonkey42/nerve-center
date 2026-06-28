defmodule NerveCenterWeb.DetailLiveTest do
  use NerveCenterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot

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

  test "source detail renders daisy ha supervisor source with sanitized addon table", %{
    conn: conn
  } do
    now = DateTime.utc_now()
    previous = SnapshotStore.snapshot(:daisy)

    on_exit(fn -> SnapshotStore.put(previous) end)

    SnapshotStore.put(%DeviceSnapshot{
      device_id: :daisy,
      label: "DAISY",
      status: :degraded,
      updated_at: now,
      offline_expected: false,
      metrics: %{},
      sources: %{
        ha_web_socket: ok_source(:daisy, :ha_web_socket, now),
        ha_rest_probe: ok_source(:daisy, :ha_rest_probe, now),
        ha_supervisor: %SourceSnapshot{
          device_id: :daisy,
          source: :ha_supervisor,
          status: :error,
          observed_at: now,
          last_ok_at: now,
          last_error_at: nil,
          last_error: nil,
          probe_data: %{ok: true},
          consecutive_failures: 0,
          backoff_ms: 0,
          ever_ok?: true,
          metrics: %{},
          data: %{
            "summary" => %{
              "status" => "error",
              "problem_count" => 2,
              "required_unhealthy_count" => 1,
              "optional_unhealthy_count" => 0,
              "update_available_count" => 1,
              "message" => "Network UPS Tools has nut_username_blank and nut_password_blank."
            },
            "supervisor" => %{
              "healthy" => true,
              "supported" => true,
              "token" => "supervisor-token-should-not-leak"
            },
            "addons" => [
              %{
                "slug" => "a0d7b954_nut",
                "label" => "Network UPS Tools",
                "name" => "Network UPS Tools",
                "required" => true,
                "state" => "stopped",
                "status" => "error",
                "version" => "0.18.0",
                "version_latest" => "0.19.0",
                "update_available" => true,
                "config_summary" => %{"password" => "raw-nut-password-should-not-leak"},
                "config_warnings" => [
                  %{
                    "code" => "nut_username_blank",
                    "detail" => "supervisor-token-should-not-leak"
                  },
                  %{
                    "code" => "nut_password_blank",
                    "detail" => "raw-nut-password-should-not-leak"
                  }
                ]
              }
            ]
          }
        }
      }
    })

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "Network UPS Tools"
    assert html =~ "a0d7b954_nut"
    assert html =~ "stopped"
    assert html =~ "0.18.0"
    assert html =~ "0.19.0"
    assert html =~ "Config Warnings"
    assert html =~ "nut_username_blank"
    assert html =~ "nut_password_blank"
    refute html =~ "raw-nut-password-should-not-leak"
    refute html =~ "supervisor-token-should-not-leak"
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

  defp ok_source(device_id, source, now) do
    %SourceSnapshot{
      device_id: device_id,
      source: source,
      status: :ok,
      observed_at: now,
      last_ok_at: now,
      last_error_at: nil,
      last_error: nil,
      probe_data: %{ok: true},
      consecutive_failures: 0,
      backoff_ms: 0,
      ever_ok?: true,
      metrics: %{},
      data: %{}
    }
  end
end
