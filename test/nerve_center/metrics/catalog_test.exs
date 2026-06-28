defmodule NerveCenter.Metrics.CatalogTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Metrics.Catalog

  test "defines HA Supervisor aggregate metrics" do
    expected = %{
      ha_supervisor_healthy_flag: %{
        unit: :flag,
        value_type: :integer,
        display_format: :boolean,
        rollup?: true,
        prometheus_name: "ha_supervisor_healthy_flag"
      },
      ha_supervisor_supported_flag: %{
        unit: :flag,
        value_type: :integer,
        display_format: :boolean,
        rollup?: true,
        prometheus_name: "ha_supervisor_supported_flag"
      },
      ha_supervisor_required_addons_unhealthy_count: %{
        unit: :count,
        value_type: :integer,
        display_format: :count,
        rollup?: true,
        prometheus_name: "ha_supervisor_required_addons_unhealthy_count"
      },
      ha_supervisor_optional_addons_unhealthy_count: %{
        unit: :count,
        value_type: :integer,
        display_format: :count,
        rollup?: true,
        prometheus_name: "ha_supervisor_optional_addons_unhealthy_count"
      },
      ha_supervisor_addons_update_available_count: %{
        unit: :count,
        value_type: :integer,
        display_format: :count,
        rollup?: true,
        prometheus_name: "ha_supervisor_addons_update_available_count"
      },
      ha_supervisor_addons_config_warning_count: %{
        unit: :count,
        value_type: :integer,
        display_format: :count,
        rollup?: true,
        prometheus_name: "ha_supervisor_addons_config_warning_count"
      }
    }

    for {metric_id, attrs} <- expected do
      assert definition = Catalog.definition(metric_id)
      assert Map.take(definition, Map.keys(attrs)) == attrs
    end
  end
end
