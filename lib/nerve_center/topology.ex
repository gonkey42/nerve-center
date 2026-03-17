defmodule NerveCenter.Topology do
  @moduledoc false

  @devices Application.compile_env(:nerve_center, :devices, [])

  def all_devices, do: @devices

  def enabled_devices do
    Enum.filter(@devices, & &1.enabled)
  end

  def display_devices do
    @devices
    |> Enum.filter(& &1.enabled)
    |> Enum.sort_by(& &1.display_order)
  end

  def get_device!(device_id) when is_atom(device_id) do
    Enum.find(@devices, &(&1.id == device_id)) ||
      raise ArgumentError, "unknown device #{inspect(device_id)}"
  end

  def get_device!(device_id) when is_binary(device_id) do
    device_id
    |> String.to_existing_atom()
    |> get_device!()
  rescue
    ArgumentError -> raise ArgumentError, "unknown device #{inspect(device_id)}"
  end

  def enabled_sources do
    for device <- enabled_devices(),
        source <- Enum.filter(device.sources, & &1.enabled) do
      {device, source}
    end
  end

  def source_topic(device_id, source_name) do
    "source:#{device_id}:#{source_name}"
  end

  def device_topic(device_id) do
    "device:#{device_id}"
  end

  def app_health_topic do
    "app:health"
  end
end
