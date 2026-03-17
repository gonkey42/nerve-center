defmodule NerveCenter.Sources.Stig.UniFiSourceTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Sources.Stig.UniFiSource

  test "probe advertises scoped tls verification and api key auth" do
    context = %{
      device: %{
        unifi_base_url: "https://192.168.0.1",
        unifi_site_slug: "default"
      }
    }

    assert {:ok, probe_data} = UniFiSource.probe(context)
    assert probe_data.auth == "x-api-key"
    assert probe_data.tls_verification == "scoped_verify_none"
    assert probe_data.api_base_url == "https://192.168.0.1/proxy/network/api/s/default"
  end

  test "normalize maps gateway and client data into canonical metrics" do
    raw = %{
      health: [
        %{
          "subsystem" => "wan",
          "status" => "ok",
          "wan_ip" => "45.52.141.184",
          "gw_name" => "Stig",
          "gw_version" => "5.0.12.30269",
          "gw_system-stats" => %{"cpu" => "5.7", "mem" => "63.5", "uptime" => "2742232"},
          "isp_name" => "Frontier Communications"
        }
      ],
      devices: [
        %{
          "name" => "Stig",
          "type" => "udm",
          "model" => "UDRULT",
          "version" => "5.0.12.30269",
          "uptime" => 2_742_253,
          "system-stats" => %{"cpu" => "5.7", "mem" => "63.4", "uptime" => "2742253"},
          "uplink" => %{
            "name" => "eth4",
            "up" => true,
            "media" => "2.5GE",
            "ip" => "45.52.141.184",
            "latency" => 9
          }
        }
      ],
      clients: [
        %{
          "name" => "Livingroom ESP32",
          "hostname" => "livingroom-esp32",
          "ip" => "20.20.20.151",
          "mac" => "a4:cf:12:88:c1:e8",
          "is_wired" => true,
          "last_seen" => 1_773_712_926
        },
        %{
          "name" => "HAL9000",
          "hostname" => "hal9000",
          "ip" => "20.20.20.10",
          "mac" => "00:11:22:33:44:55",
          "is_wired" => true,
          "last_seen" => 1_773_712_930
        }
      ]
    }

    assert {:ok, payload} = UniFiSource.normalize(raw, %{})

    metrics = Map.new(payload.metrics, &{&1.metric, &1.value})

    assert metrics.unifi_clients_connected_count == 2
    assert metrics.unifi_wan_up_flag == 1
    assert_in_delta metrics.unifi_gateway_cpu_ratio, 0.057, 0.0001
    assert_in_delta metrics.unifi_gateway_memory_ratio, 0.634, 0.0001

    assert payload.data.gateway_name == "Stig"
    assert payload.data.gateway_model == "UDRULT"
    assert payload.data.gateway_version == "5.0.12.30269"
    assert payload.data.wan_status == "ok"
    assert payload.data.wan_ip == "45.52.141.184"
    assert payload.data.connected_clients_count == 2
    assert payload.data.gateway_uplink.up

    assert [
             %{hostname: "livingroom-esp32", wired?: true},
             %{hostname: "hal9000", wired?: true}
           ] = payload.data.clients
  end
end
