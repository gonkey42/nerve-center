defmodule NerveCenter.Sources.Daisy.HAWebSocketSource do
  @moduledoc false

  use NerveCenter.Runtime.StreamingSource

  @impl true
  def required_env, do: ["HA_TOKEN"]

  @impl true
  def stale_after_ms, do: 90_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       auth: "long_lived_token",
       event_type: "state_changed",
       websocket_path: "/api/websocket",
       curated_entity_ids: context.device.curated_entity_ids
     }}
  end

  @impl true
  def connect(context) do
    uri = URI.parse("#{context.device.home_assistant_base_url}/api/websocket")

    {:ok,
     %{
       scheme: websocket_scheme(uri.scheme),
       transport_scheme: transport_scheme(uri.scheme),
       host: uri.host,
       port: uri.port || default_port(uri.scheme),
       path: uri.path || "/api/websocket",
       private: fresh_private(context.device.curated_entity_ids)
     }}
  end

  @impl true
  def handle_frame(%{"type" => "auth_required", "ha_version" => version}, context) do
    {:ok,
     %{
       private: Map.put(context.private, :ha_version, version),
       outbound: [%{"type" => "auth", "access_token" => System.fetch_env!("HA_TOKEN")}]
     }}
  end

  def handle_frame(%{"type" => "auth_ok", "ha_version" => version}, context) do
    private =
      context.private
      |> Map.put(:ha_version, version)
      |> Map.put(:subscription_id, 1)
      |> Map.put(:states_request_id, 2)

    {:ok,
     %{
       private: private,
       outbound: [
         %{"id" => 1, "type" => "subscribe_events", "event_type" => "state_changed"},
         %{"id" => 2, "type" => "get_states"}
       ]
     }}
  end

  def handle_frame(%{"type" => "auth_invalid", "message" => message}, _context) do
    {:error, {:auth_invalid, message}}
  end

  def handle_frame(
        %{"type" => "result", "id" => id, "success" => false, "error" => error},
        context
      ) do
    command = command_name(context.private, id)
    {:error, {:ha_command_failed, command, error}}
  end

  def handle_frame(%{"type" => "result", "id" => id, "success" => true}, context)
      when id == context.private.subscription_id do
    {:ok, %{private: Map.put(context.private, :subscribed?, true)}}
  end

  def handle_frame(
        %{"type" => "result", "id" => id, "success" => true, "result" => states},
        context
      )
      when id == context.private.states_request_id do
    private =
      Map.put(
        context.private,
        :entities,
        build_entities(states, context.device.curated_entity_ids)
      )

    {:ok,
     %{
       private: private,
       snapshot: snapshot_payload(private, context.device.curated_entity_ids)
     }}
  end

  def handle_frame(
        %{
          "type" => "event",
          "id" => id,
          "event" => %{
            "data" => %{"entity_id" => entity_id, "new_state" => new_state},
            "time_fired" => time_fired
          }
        },
        context
      )
      when id == context.private.subscription_id do
    if entity_id in context.device.curated_entity_ids do
      private = update_entity(context.private, entity_id, new_state)

      {:ok,
       %{
         private: private,
         snapshot:
           snapshot_payload(
             private,
             context.device.curated_entity_ids,
             parse_timestamp(time_fired)
           )
       }}
    else
      {:ok, %{private: context.private}}
    end
  end

  def handle_frame(%{"type" => "event"}, context) do
    {:ok, %{private: context.private}}
  end

  def handle_frame(_frame, context) do
    {:ok, %{private: context.private}}
  end

  @impl true
  def handle_disconnect(reason, context) do
    {:ok,
     %{
       private: fresh_private(context.device.curated_entity_ids),
       reason: reason
     }}
  end

  defp fresh_private(entity_ids) do
    %{
      curated_entity_ids: entity_ids,
      entities: %{},
      subscribed?: false,
      subscription_id: nil,
      states_request_id: nil,
      ha_version: nil
    }
  end

  defp command_name(private, id) when id == private.subscription_id, do: :subscribe_events
  defp command_name(private, id) when id == private.states_request_id, do: :get_states
  defp command_name(_private, _id), do: :unknown

  defp build_entities(states, entity_ids) do
    states
    |> Enum.reduce(%{}, fn
      %{"entity_id" => entity_id} = state, acc ->
        if entity_id in entity_ids do
          Map.put(acc, entity_id, entity_from_state(state))
        else
          acc
        end

      _state, acc ->
        acc
    end)
  end

  defp update_entity(private, entity_id, nil) do
    update_in(private.entities, &Map.delete(&1, entity_id))
  end

  defp update_entity(private, entity_id, new_state) do
    put_in(private.entities[entity_id], entity_from_state(new_state))
  end

  defp snapshot_payload(private, entity_ids, observed_at \\ DateTime.utc_now()) do
    %{
      observed_at: observed_at,
      data: %{
        ha_version: private.ha_version,
        entities: snapshot_entities(private.entities, entity_ids)
      }
    }
  end

  defp snapshot_entities(entities, entity_ids) do
    entity_ids
    |> Enum.map(&Map.get(entities, &1))
    |> Enum.reject(&is_nil/1)
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
      last_changed: parse_timestamp(state["last_changed"]),
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

  defp websocket_scheme("https"), do: :wss
  defp websocket_scheme(_scheme), do: :ws

  defp transport_scheme("https"), do: :https
  defp transport_scheme(_scheme), do: :http

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80
end
