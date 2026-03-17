defmodule NerveCenter.Sources.Daisy.HAWebSocketSourceTest do
  use ExUnit.Case, async: true

  alias NerveCenter.Sources.Daisy.HAWebSocketSource

  setup do
    previous = System.get_env("HA_TOKEN")
    System.put_env("HA_TOKEN", "test-ha-token")

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("HA_TOKEN")
      else
        System.put_env("HA_TOKEN", previous)
      end
    end)

    :ok
  end

  test "auth_required requests token auth" do
    context = context()

    assert {:ok, result} =
             HAWebSocketSource.handle_frame(
               %{"type" => "auth_required", "ha_version" => "2026.2.3"},
               context
             )

    assert result.private.ha_version == "2026.2.3"
    assert result.outbound == [%{"type" => "auth", "access_token" => "test-ha-token"}]
  end

  test "auth_ok subscribes to state changes and requests current states" do
    context = context()

    assert {:ok, result} =
             HAWebSocketSource.handle_frame(
               %{"type" => "auth_ok", "ha_version" => "2026.2.3"},
               context
             )

    assert result.private.subscription_id == 1
    assert result.private.states_request_id == 2

    assert result.outbound == [
             %{"id" => 1, "type" => "subscribe_events", "event_type" => "state_changed"},
             %{"id" => 2, "type" => "get_states"}
           ]
  end

  test "get_states result builds snapshot data for curated entities" do
    private = %{context().private | subscription_id: 1, states_request_id: 2}

    assert {:ok, result} =
             HAWebSocketSource.handle_frame(
               %{
                 "type" => "result",
                 "id" => 2,
                 "success" => true,
                 "result" => [
                   %{
                     "entity_id" => "weather.home",
                     "state" => "snowy",
                     "last_changed" => "2026-03-17T01:00:00Z",
                     "last_updated" => "2026-03-17T01:00:00Z",
                     "attributes" => %{"friendly_name" => "Weather Home"}
                   },
                   %{
                     "entity_id" => "sensor.other",
                     "state" => "ignored",
                     "last_changed" => "2026-03-17T01:00:00Z",
                     "last_updated" => "2026-03-17T01:00:00Z",
                     "attributes" => %{"friendly_name" => "Other"}
                   }
                 ]
               },
               %{context() | private: private}
             )

    assert [%{entity_id: "weather.home", friendly_name: "Weather Home", state: "snowy"}] =
             result.snapshot.data.entities
  end

  test "state_changed updates curated entities only" do
    private = %{
      context().private
      | subscription_id: 1,
        states_request_id: 2,
        entities: %{
          "weather.home" => %{
            entity_id: "weather.home",
            friendly_name: "Weather Home",
            state: "snowy",
            unit_of_measurement: nil,
            last_changed: DateTime.utc_now(),
            last_updated: DateTime.utc_now()
          }
        }
    }

    assert {:ok, result} =
             HAWebSocketSource.handle_frame(
               %{
                 "type" => "event",
                 "id" => 1,
                 "event" => %{
                   "time_fired" => "2026-03-17T01:05:00Z",
                   "data" => %{
                     "entity_id" => "weather.home",
                     "new_state" => %{
                       "entity_id" => "weather.home",
                       "state" => "windy",
                       "last_changed" => "2026-03-17T01:05:00Z",
                       "last_updated" => "2026-03-17T01:05:00Z",
                       "attributes" => %{"friendly_name" => "Weather Home"}
                     }
                   }
                 }
               },
               %{context() | private: private}
             )

    assert [%{state: "windy"}] = result.snapshot.data.entities
  end

  defp context do
    %{
      device: %{
        curated_entity_ids: ["weather.home"],
        home_assistant_base_url: "http://100.103.249.3:8123"
      },
      source: %{name: :ha_web_socket},
      private: %{
        curated_entity_ids: ["weather.home"],
        entities: %{},
        subscribed?: false,
        subscription_id: nil,
        states_request_id: nil,
        ha_version: nil
      },
      probe_data: nil,
      last_ok_at: nil,
      last_payload: %{metrics: %{}, data: %{}}
    }
  end
end
