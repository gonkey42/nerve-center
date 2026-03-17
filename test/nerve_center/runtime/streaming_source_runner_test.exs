defmodule NerveCenter.Runtime.StreamingSourceRunnerTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.StreamingSourceRunner

  defmodule FakeStreamingSource do
    use NerveCenter.Runtime.StreamingSource

    @impl true
    def required_env, do: []

    @impl true
    def probe(_context), do: {:ok, %{mode: "test"}}

    @impl true
    def stale_after_ms, do: 90_000

    @impl true
    def connect(%{source: %{script: script, test_pid: test_pid}}) do
      send(test_pid, :connect_attempt)

      Agent.get_and_update(script, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, :offline}, []}
      end)
    end

    @impl true
    def handle_frame(_frame, context), do: {:ok, %{private: context.private}}

    @impl true
    def handle_disconnect(reason, context) do
      {:ok, %{private: context.private, reason: reason}}
    end
  end

  test "connection failures schedule reconnect attempts with increasing backoff" do
    script =
      start_supervised!({Agent, fn -> [{:error, :offline}, {:error, :offline}] end})

    runner =
      start_supervised!(
        {StreamingSourceRunner,
         module: FakeStreamingSource,
         device: test_device(),
         source: %{name: :ha_web_socket, script: script, test_pid: self()}}
      )

    assert_receive :connect_attempt, 1_000
    assert :sys.get_state(runner).backoff_ms == 1_000

    reconnect_timer = :sys.get_state(runner).reconnect_timer
    send(runner, {:reconnect, reconnect_timer})

    assert_receive :connect_attempt, 1_000
    assert :sys.get_state(runner).backoff_ms == 2_000
  end

  test "bootstrap honors persisted backoff before reconnecting" do
    device = test_device()

    seed_app_health(device.id, :ha_web_socket,
      backoff_ms: 5_000,
      last_error_at: DateTime.utc_now()
    )

    script =
      start_supervised!({Agent, fn -> [{:error, :offline}] end})

    runner =
      start_supervised!(
        {StreamingSourceRunner,
         module: FakeStreamingSource,
         device: device,
         source: %{name: :ha_web_socket, script: script, test_pid: self()}}
      )

    refute_receive :connect_attempt, 200

    reconnect_timer = :sys.get_state(runner).reconnect_timer
    assert reconnect_timer

    send(runner, {:reconnect, reconnect_timer})

    assert_receive :connect_attempt, 1_000
  end

  defp test_device do
    %{
      id: :"streaming_source_test_#{System.unique_integer([:positive])}",
      label: "Streaming Source Test",
      offline_expected: false
    }
  end

  defp seed_app_health(device_id, source_name, overrides) do
    source_state =
      %{
        device_id: device_id,
        source: source_name,
        last_ok_at: nil,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error_at: nil,
        last_error: nil
      }
      |> Map.merge(Map.new(overrides))

    :sys.replace_state(AppHealth, fn state ->
      %{state | sources: Map.put(state.sources, {device_id, source_name}, source_state)}
    end)

    on_exit(fn ->
      :sys.replace_state(AppHealth, fn state ->
        update_in(state.sources, &Map.delete(&1, {device_id, source_name}))
      end)
    end)
  end
end
