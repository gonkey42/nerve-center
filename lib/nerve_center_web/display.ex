defmodule NerveCenterWeb.Display do
  @moduledoc false

  alias NerveCenter.Metrics.Catalog

  @source_names %{
    frigate: "Frigate",
    frigate_preview: "Frigate Preview",
    glances: "Glances",
    ha_rest_probe: "Home Assistant REST",
    ha_supervisor: "HA Supervisor",
    ha_web_socket: "Home Assistant Stream",
    immich: "Immich",
    launchd: "Launch Agents",
    local_metrics: "Local Metrics",
    nut: "UPS",
    pihole: "Pi-hole",
    plex: "Plex",
    unifi: "UniFi"
  }

  def source_name(%{name: source_name}), do: source_name(source_name)
  def source_name(%{source: source_name}), do: source_name(source_name)

  def source_name(source_name) when is_atom(source_name) do
    Map.get(@source_names, source_name, humanize(source_name))
  end

  def source_name(source_name) when is_binary(source_name) do
    source_name
    |> String.to_existing_atom()
    |> source_name()
  rescue
    ArgumentError -> humanize(source_name)
  end

  def percent(nil), do: "-"
  def percent(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"

  def bytes(nil), do: "-"
  def bytes(value) when value < 1024, do: "#{round(value)} B"
  def bytes(value) when value < 1_048_576, do: "#{Float.round(value / 1024, 1)} KiB"
  def bytes(value) when value < 1_073_741_824, do: "#{Float.round(value / 1_048_576, 1)} MiB"
  def bytes(value), do: "#{Float.round(value / 1_073_741_824, 1)} GiB"

  def throughput(value), do: "#{bytes(value)}/s"

  def duration(nil), do: "-"

  def duration(seconds) do
    total = round(seconds)
    days = div(total, 86_400)
    hours = div(rem(total, 86_400), 3_600)
    minutes = div(rem(total, 3_600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      true -> "#{minutes}m"
    end
  end

  def volts(nil), do: "-"
  def volts(value) when is_number(value), do: "#{Float.round(value / 1, 1)} V"

  def watts(nil), do: "-"
  def watts(value) when is_number(value), do: "#{Float.round(value / 1, 1)} W"

  def count(nil), do: "-"
  def count(value) when is_integer(value), do: Integer.to_string(value)
  def count(value) when is_float(value), do: Integer.to_string(round(value))

  def boolean(nil), do: "-"
  def boolean(0), do: "No"
  def boolean(value) when is_number(value) and value > 0, do: "Yes"

  def humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def metric(metric_id, value) do
    case Catalog.definition(metric_id) do
      %{display_format: :percent} -> percent(value)
      %{display_format: :bytes} -> bytes(value)
      %{display_format: :throughput} -> throughput(value)
      %{display_format: :duration} -> duration(value)
      %{display_format: :boolean} -> boolean(value)
      %{display_format: :volts} -> volts(value)
      %{display_format: :watts} -> watts(value)
      %{display_format: :count} -> count(value)
      %{display_format: :fps} -> count(value)
      _ -> to_string(value || "-")
    end
  end

  def status_class(:ok), do: "bg-emerald-500/20 text-emerald-300 ring-emerald-400/30"
  def status_class(:degraded), do: "bg-amber-500/20 text-amber-200 ring-amber-400/30"
  def status_class(:offline), do: "bg-rose-500/20 text-rose-200 ring-rose-400/30"
  def status_class(:unknown), do: "bg-stone-700/40 text-stone-200 ring-stone-500/40"
  def status_class(:stale), do: status_class(:degraded)
  def status_class(:error), do: status_class(:offline)
end
