defmodule NerveCenter.Metrics.Exporter do
  @moduledoc false

  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology

  def render(device_snapshots \\ current_device_snapshots()) do
    device_snapshots
    |> metric_entries()
    |> Enum.group_by(& &1.prometheus_name)
    |> Enum.sort_by(fn {prometheus_name, _entries} -> prometheus_name end)
    |> Enum.map_join("\n", fn {prometheus_name, entries} ->
      sample_lines =
        entries
        |> Enum.sort_by(fn entry -> {entry.device_id, entry.source} end)
        |> Enum.map(&sample_line(prometheus_name, &1))

      Enum.join(
        [
          "# HELP #{prometheus_name} #{prometheus_name}",
          "# TYPE #{prometheus_name} gauge" | sample_lines
        ],
        "\n"
      )
    end)
    |> case do
      "" -> ""
      body -> body <> "\n"
    end
  end

  defp current_device_snapshots do
    Enum.map(Topology.enabled_devices(), fn device ->
      %{device: device, snapshot: SnapshotStore.snapshot(device.id)}
    end)
  end

  defp metric_entries(device_snapshots) do
    Enum.flat_map(device_snapshots, fn %{device: device, snapshot: snapshot} ->
      (snapshot || %{sources: %{}})
      |> Map.get(:sources, %{})
      |> Enum.sort_by(fn {source_name, _source_snapshot} -> source_name end)
      |> Enum.flat_map(fn {source_name, source_snapshot} ->
        if match?(%{status: :ok}, source_snapshot) do
          source_snapshot.metrics
          |> Enum.sort_by(fn {metric_id, _value} -> metric_id end)
          |> Enum.flat_map(fn {metric_id, value} ->
            case Catalog.definition(metric_id) do
              %{prometheus_name: prometheus_name} ->
                [
                  %{
                    prometheus_name: prometheus_name,
                    device_id: device.id,
                    source: source_name,
                    value: value
                  }
                ]

              nil ->
                []
            end
          end)
        else
          []
        end
      end)
    end)
  end

  defp sample_line(prometheus_name, entry) do
    labels = [
      ~s(device_id="#{escape_label(Atom.to_string(entry.device_id))}"),
      ~s(source="#{escape_label(Atom.to_string(entry.source))}")
    ]

    "#{prometheus_name}{#{Enum.join(labels, ",")}} #{format_value(entry.value)}"
  end

  defp escape_label(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp format_value(value) when is_number(value), do: to_string(value)
end
