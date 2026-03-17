defmodule NerveCenterWeb.MetricsControllerTest do
  use NerveCenterWeb.ConnCase, async: false

  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot

  test "GET /metrics returns prometheus text for catalog metrics only", %{conn: conn} do
    now = DateTime.utc_now()
    previous = SnapshotStore.snapshot(:stig)

    on_exit(fn -> SnapshotStore.put(previous) end)

    SnapshotStore.put(%DeviceSnapshot{
      device_id: :stig,
      label: "Stig",
      status: :ok,
      updated_at: now,
      offline_expected: false,
      metrics: %{},
      sources: %{
        unifi: %SourceSnapshot{
          device_id: :stig,
          source: :unifi,
          status: :ok,
          observed_at: now,
          last_ok_at: now,
          last_error_at: nil,
          last_error: nil,
          probe_data: %{},
          consecutive_failures: 0,
          backoff_ms: 0,
          ever_ok?: true,
          metrics: %{
            unifi_wan_up_flag: 1,
            unifi_clients_connected_count: 19,
            unifi_gateway_cpu_ratio: 0.057,
            unknown_phase3_metric: 42
          },
          data: %{}
        }
      }
    })

    conn = get(conn, ~p"/metrics")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
    assert body =~ "# TYPE unifi_clients_connected_count gauge"
    assert body =~ ~s(unifi_wan_up_flag{device_id="stig",source="unifi"} 1)
    assert body =~ ~s(unifi_gateway_cpu_ratio{device_id="stig",source="unifi"} 0.057)
    refute body =~ "unknown_phase3_metric"
  end
end
