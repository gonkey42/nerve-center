defmodule NerveCenter.Metrics.Catalog do
  @moduledoc false

  @metrics %{
    cpu_util_ratio: %{
      id: :cpu_util_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "cpu_util_ratio"
    },
    memory_used_bytes: %{
      id: :memory_used_bytes,
      unit: :bytes,
      value_type: :integer,
      display_format: :bytes,
      rollup?: true,
      prometheus_name: "memory_used_bytes"
    },
    memory_total_bytes: %{
      id: :memory_total_bytes,
      unit: :bytes,
      value_type: :integer,
      display_format: :bytes,
      rollup?: true,
      prometheus_name: "memory_total_bytes"
    },
    disk_used_bytes: %{
      id: :disk_used_bytes,
      unit: :bytes,
      value_type: :integer,
      display_format: :bytes,
      rollup?: true,
      prometheus_name: "disk_used_bytes"
    },
    disk_total_bytes: %{
      id: :disk_total_bytes,
      unit: :bytes,
      value_type: :integer,
      display_format: :bytes,
      rollup?: true,
      prometheus_name: "disk_total_bytes"
    },
    network_rx_bytes_per_sec: %{
      id: :network_rx_bytes_per_sec,
      unit: :bytes_per_sec,
      value_type: :float,
      display_format: :throughput,
      rollup?: true,
      prometheus_name: "network_rx_bytes_per_sec"
    },
    network_tx_bytes_per_sec: %{
      id: :network_tx_bytes_per_sec,
      unit: :bytes_per_sec,
      value_type: :float,
      display_format: :throughput,
      rollup?: true,
      prometheus_name: "network_tx_bytes_per_sec"
    },
    uptime_seconds: %{
      id: :uptime_seconds,
      unit: :seconds,
      value_type: :integer,
      display_format: :duration,
      rollup?: true,
      prometheus_name: "uptime_seconds"
    },
    plex_active_streams_count: %{
      id: :plex_active_streams_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "plex_active_streams_count"
    },
    pihole_queries_today_count: %{
      id: :pihole_queries_today_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "pihole_queries_today_count"
    },
    pihole_blocked_queries_today_count: %{
      id: :pihole_blocked_queries_today_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "pihole_blocked_queries_today_count"
    },
    pihole_blocked_ratio: %{
      id: :pihole_blocked_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "pihole_blocked_ratio"
    },
    pihole_blocking_enabled_flag: %{
      id: :pihole_blocking_enabled_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "pihole_blocking_enabled_flag"
    },
    ups_battery_charge_ratio: %{
      id: :ups_battery_charge_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "ups_battery_charge_ratio"
    },
    ups_battery_runtime_seconds: %{
      id: :ups_battery_runtime_seconds,
      unit: :seconds,
      value_type: :integer,
      display_format: :duration,
      rollup?: true,
      prometheus_name: "ups_battery_runtime_seconds"
    },
    ups_load_ratio: %{
      id: :ups_load_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "ups_load_ratio"
    },
    ups_current_load_watts: %{
      id: :ups_current_load_watts,
      unit: :watts,
      value_type: :float,
      display_format: :watts,
      rollup?: true,
      prometheus_name: "ups_current_load_watts"
    },
    ups_input_voltage_volts: %{
      id: :ups_input_voltage_volts,
      unit: :volts,
      value_type: :float,
      display_format: :volts,
      rollup?: true,
      prometheus_name: "ups_input_voltage_volts"
    },
    ups_on_battery_flag: %{
      id: :ups_on_battery_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "ups_on_battery_flag"
    },
    ups_low_battery_flag: %{
      id: :ups_low_battery_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "ups_low_battery_flag"
    },
    ha_supervisor_healthy_flag: %{
      id: :ha_supervisor_healthy_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "ha_supervisor_healthy_flag"
    },
    ha_supervisor_supported_flag: %{
      id: :ha_supervisor_supported_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "ha_supervisor_supported_flag"
    },
    ha_supervisor_required_addons_unhealthy_count: %{
      id: :ha_supervisor_required_addons_unhealthy_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "ha_supervisor_required_addons_unhealthy_count"
    },
    ha_supervisor_optional_addons_unhealthy_count: %{
      id: :ha_supervisor_optional_addons_unhealthy_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "ha_supervisor_optional_addons_unhealthy_count"
    },
    ha_supervisor_addons_update_available_count: %{
      id: :ha_supervisor_addons_update_available_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "ha_supervisor_addons_update_available_count"
    },
    ha_supervisor_addons_config_warning_count: %{
      id: :ha_supervisor_addons_config_warning_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "ha_supervisor_addons_config_warning_count"
    },
    frigate_detection_fps: %{
      id: :frigate_detection_fps,
      unit: :count,
      value_type: :float,
      display_format: :fps,
      rollup?: true,
      prometheus_name: "frigate_detection_fps"
    },
    frigate_process_fps: %{
      id: :frigate_process_fps,
      unit: :count,
      value_type: :float,
      display_format: :fps,
      rollup?: true,
      prometheus_name: "frigate_process_fps"
    },
    immich_assets_count: %{
      id: :immich_assets_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "immich_assets_count"
    },
    immich_images_count: %{
      id: :immich_images_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "immich_images_count"
    },
    immich_videos_count: %{
      id: :immich_videos_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "immich_videos_count"
    },
    immich_storage_used_bytes: %{
      id: :immich_storage_used_bytes,
      unit: :bytes,
      value_type: :integer,
      display_format: :bytes,
      rollup?: true,
      prometheus_name: "immich_storage_used_bytes"
    },
    unifi_clients_connected_count: %{
      id: :unifi_clients_connected_count,
      unit: :count,
      value_type: :integer,
      display_format: :count,
      rollup?: true,
      prometheus_name: "unifi_clients_connected_count"
    },
    unifi_wan_up_flag: %{
      id: :unifi_wan_up_flag,
      unit: :flag,
      value_type: :integer,
      display_format: :boolean,
      rollup?: true,
      prometheus_name: "unifi_wan_up_flag"
    },
    unifi_gateway_cpu_ratio: %{
      id: :unifi_gateway_cpu_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "unifi_gateway_cpu_ratio"
    },
    unifi_gateway_memory_ratio: %{
      id: :unifi_gateway_memory_ratio,
      unit: :ratio,
      value_type: :float,
      display_format: :percent,
      rollup?: true,
      prometheus_name: "unifi_gateway_memory_ratio"
    }
  }

  require Logger

  def definitions, do: @metrics

  def definition(metric_id) when is_binary(metric_id) do
    metric_id
    |> String.to_existing_atom()
    |> definition()
  rescue
    ArgumentError -> nil
  end

  def definition(metric_id) when is_atom(metric_id), do: Map.get(@metrics, metric_id)

  def normalize(metric_entries) do
    Enum.reduce(metric_entries, [], fn %{metric: metric_id, value: value} = entry, acc ->
      case definition(metric_id) do
        nil ->
          Logger.warning("rejecting unknown metric #{inspect(metric_id)}")
          acc

        metric ->
          [
            %{
              metric_id: metric.id,
              metric_name: Atom.to_string(metric.id),
              metric_value: normalize_value(metric.value_type, value),
              display_format: metric.display_format,
              unit: metric.unit,
              rollup?: metric.rollup?,
              prometheus_name: metric.prometheus_name,
              source_data: Map.get(entry, :source_data)
            }
            | acc
          ]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_value(:integer, value) when is_integer(value), do: value
  defp normalize_value(:integer, value) when is_float(value), do: round(value)
  defp normalize_value(:integer, value) when is_binary(value), do: String.to_integer(value)
  defp normalize_value(:float, value) when is_integer(value), do: value / 1
  defp normalize_value(:float, value), do: value
end
