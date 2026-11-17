defmodule NerveCenter.HomeAssistant.Client do
  @moduledoc false

  alias NerveCenter.Sources.Support

  def list_states(device) do
    with {:ok, states} <-
           Support.request_json("#{device.home_assistant_base_url}/api/states",
             headers: [{"authorization", "Bearer #{System.fetch_env!("HA_TOKEN")}"}]
           ) do
      {:ok, Enum.map(states, &entity_from_state/1)}
    end
  end

  defp entity_from_state(state) do
    attributes = state["attributes"] || %{}

    %{
      entity_id: state["entity_id"],
      friendly_name: attributes["friendly_name"] || state["entity_id"],
      state: state["state"],
      unit_of_measurement: attributes["unit_of_measurement"],
      device_class: attributes["device_class"],
      icon: attributes["icon"],
      last_updated: parse_timestamp(state["last_updated"])
    }
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> DateTime.utc_now()
    end
  end
end
