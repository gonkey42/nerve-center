defmodule NerveCenter.Metrics.ExporterTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Metrics.Exporter
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot

  test "render exports only catalog metrics from healthy sources" do
    now = DateTime.utc_now()

    device_snapshots = [
      %{
        device: %{id: :stig},
        snapshot: %DeviceSnapshot{
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
                unifi_gateway_cpu_ratio: 0.057,
                unknown_phase3_metric: 99
              },
              data: %{}
            }
          }
        }
      },
      %{
        device: %{id: :zoidberg},
        snapshot: %DeviceSnapshot{
          device_id: :zoidberg,
          label: "Zoidberg",
          status: :offline,
          updated_at: now,
          offline_expected: true,
          metrics: %{},
          sources: %{
            glances: %SourceSnapshot{
              device_id: :zoidberg,
              source: :glances,
              status: :offline,
              observed_at: now,
              last_ok_at: now,
              last_error_at: now,
              last_error: "offline",
              probe_data: %{},
              consecutive_failures: 1,
              backoff_ms: 300_000,
              ever_ok?: true,
              metrics: %{cpu_util_ratio: 0.25},
              data: %{}
            }
          }
        }
      },
      %{
        device: %{id: :daisy},
        snapshot: %DeviceSnapshot{
          device_id: :daisy,
          label: "DAISY",
          status: :ok,
          updated_at: now,
          offline_expected: false,
          metrics: %{},
          sources: %{
            ha_supervisor: %SourceSnapshot{
              device_id: :daisy,
              source: :ha_supervisor,
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
                ha_supervisor_healthy_flag: 1,
                ha_supervisor_required_addons_unhealthy_count: 0
              },
              data: %{}
            }
          }
        }
      },
      %{
        device: %{id: :daisy},
        snapshot: %DeviceSnapshot{
          device_id: :daisy,
          label: "DAISY",
          status: :error,
          updated_at: now,
          offline_expected: false,
          metrics: %{},
          sources: %{
            ha_supervisor: %SourceSnapshot{
              device_id: :daisy,
              source: :ha_supervisor,
              status: :error,
              observed_at: now,
              last_ok_at: now,
              last_error_at: now,
              last_error: "bridge unavailable",
              probe_data: %{},
              consecutive_failures: 1,
              backoff_ms: 60_000,
              ever_ok?: true,
              metrics: %{
                ha_supervisor_addons_config_warning_count: 2
              },
              data: %{}
            }
          }
        }
      },
      %{
        device: %{id: :daisy},
        snapshot: %DeviceSnapshot{
          device_id: :daisy,
          label: "DAISY",
          status: :degraded,
          updated_at: now,
          offline_expected: false,
          metrics: %{},
          sources: %{
            ha_supervisor: %SourceSnapshot{
              device_id: :daisy,
              source: :ha_supervisor,
              status: :degraded,
              observed_at: now,
              last_ok_at: now,
              last_error_at: nil,
              last_error: nil,
              probe_data: %{},
              consecutive_failures: 0,
              backoff_ms: 0,
              ever_ok?: true,
              metrics: %{
                ha_supervisor_supported_flag: 0
              },
              data: %{}
            }
          }
        }
      },
      %{
        device: %{id: :ups},
        snapshot: %DeviceSnapshot{
          device_id: :ups,
          label: "UPS",
          status: :ok,
          updated_at: now,
          offline_expected: false,
          metrics: %{},
          sources: %{
            nut: %SourceSnapshot{
              device_id: :ups,
              source: :nut,
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
                ups_battery_charge_ratio: 1.0,
                ups_load_ratio: 0.3
              },
              data: %{}
            }
          }
        }
      }
    ]

    body = Exporter.render(device_snapshots)

    assert body =~ "# TYPE unifi_gateway_cpu_ratio gauge"
    assert body =~ ~s(unifi_gateway_cpu_ratio{device_id="stig",source="unifi"} 0.057)
    assert body =~ ~s(unifi_wan_up_flag{device_id="stig",source="unifi"} 1)
    assert body =~ "# TYPE ha_supervisor_healthy_flag gauge"
    assert body =~ ~s(ha_supervisor_healthy_flag{device_id="daisy",source="ha_supervisor"} 1)

    assert body =~
             ~s(ha_supervisor_required_addons_unhealthy_count{device_id="daisy",source="ha_supervisor"} 0)

    refute body =~
             ~s(ha_supervisor_addons_config_warning_count{device_id="daisy",source="ha_supervisor"} 2)

    refute body =~ ~s(ha_supervisor_supported_flag{device_id="daisy",source="ha_supervisor"} 0)
    assert body =~ "# TYPE ups_battery_charge_ratio gauge"
    assert body =~ ~s(ups_battery_charge_ratio{device_id="ups",source="nut"} 1)
    assert body =~ ~s(ups_load_ratio{device_id="ups",source="nut"} 0.3)
    refute body =~ "unknown_phase3_metric"
    refute body =~ ~s(cpu_util_ratio{device_id="zoidberg",source="glances"})
  end
end
