defmodule NerveCenterWeb.DashboardLiveTest do
  use NerveCenterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot

  test "dashboard omits explanatory subtitle copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~
             "Live state for the enabled devices, sourced locally, across the tailnet, and from the LAN gateway without any write actions."
  end

  test "launchd services render friendly app names", %{conn: conn} do
    now = DateTime.utc_now()
    previous = SnapshotStore.snapshot(:hal9000)

    on_exit(fn -> SnapshotStore.put(previous) end)

    SnapshotStore.put(%DeviceSnapshot{
      device_id: :hal9000,
      label: "HAL9000",
      status: :ok,
      updated_at: now,
      offline_expected: false,
      metrics: %{},
      sources: %{
        launchd: %SourceSnapshot{
          device_id: :hal9000,
          source: :launchd,
          status: :ok,
          observed_at: now,
          last_ok_at: now,
          last_error_at: nil,
          last_error: nil,
          probe_data: %{},
          consecutive_failures: 0,
          backoff_ms: 0,
          ever_ok?: true,
          metrics: %{},
          data: %{
            services: [
              %{
                label: "com.claudebot.youtube-ripper",
                display_name: "YouTube Ripper",
                running: true,
                pid: 123,
                last_exit_status: 0
              },
              %{
                label: "com.spendsense.app",
                display_name: "SpendSense",
                running: true,
                pid: 456,
                last_exit_status: 0
              },
              %{
                label: "com.claudebot.nerve-center",
                display_name: "Nerve Center",
                running: true,
                pid: 789,
                last_exit_status: 0
              }
            ]
          }
        }
      }
    })

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "YouTube Ripper"
    assert html =~ "SpendSense"
    assert html =~ "Nerve Center"
    refute html =~ "com.claudebot.youtube-ripper"
    refute html =~ "com.spendsense.app"
    refute html =~ "com.claudebot.nerve-center"
  end
end
