defmodule NerveCenter.Runtime.StreamingSourceRunnerTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.StreamingSourceRunner
  alias NerveCenter.Sources.Daisy.HAWebSocketSource
  alias NerveCenter.Topology

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

  test "auth rejections back off instead of reconnecting in a tight loop" do
    {listener, port} = listen_socket()

    server =
      Task.async(fn ->
        Enum.each(1..2, fn _attempt ->
          {:ok, socket} = :gen_tcp.accept(listener)
          perform_websocket_handshake(socket)
          send_text_frame(socket, %{"type" => "auth_required", "ha_version" => "2026.2.3"})
          maybe_recv_client_frame(socket)
          send_text_frame(socket, %{"type" => "auth_invalid", "message" => "bad token"})
          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
      end)

    device = ha_device(port)
    clear_app_health_source_on_exit(device.id, :ha_web_socket)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_web_socket))

    runner =
      start_supervised!(
        {StreamingSourceRunner,
         module: HAWebSocketSource, device: device, source: %{name: :ha_web_socket}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: first_snapshot}, 1_000
    assert first_snapshot.last_error =~ "auth_invalid"

    first_state = wait_until_state(runner, &(&1.backoff_ms == 60_000))
    assert first_state.reconnect_timer

    send(runner, {:reconnect, first_state.reconnect_timer})

    assert_receive %SourceSnapshotUpdated{source_snapshot: second_snapshot}, 1_000
    assert second_snapshot.last_error =~ "auth_invalid"

    second_state = wait_until_state(runner, &(&1.backoff_ms == 120_000))
    assert second_state.reconnect_timer
    assert Process.alive?(runner)

    Task.await(server)
  end

  test "websocket protocol decode errors disconnect without crashing the runner" do
    {listener, port} = listen_socket()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        perform_websocket_handshake(socket)
        send_raw_frame(socket, <<0xC1, 0x00>>)
        Process.sleep(200)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    device = ha_device(port)
    clear_app_health_source_on_exit(device.id, :ha_web_socket)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_web_socket))

    runner =
      start_supervised!(
        {StreamingSourceRunner,
         module: HAWebSocketSource, device: device, source: %{name: :ha_web_socket}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: snapshot}, 1_000
    assert snapshot.last_error
    assert snapshot.status == :unknown
    assert Process.alive?(runner)

    Task.await(server)
  end

  defp test_device do
    %{
      id: :"streaming_source_test_#{System.unique_integer([:positive])}",
      label: "Streaming Source Test",
      offline_expected: false
    }
  end

  defp ha_device(port) do
    %{
      id: :"ha_streaming_test_#{System.unique_integer([:positive])}",
      label: "Home Assistant Test",
      offline_expected: false,
      home_assistant_base_url: "http://127.0.0.1:#{port}",
      curated_entity_ids: ["weather.home"]
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

  defp clear_app_health_source_on_exit(device_id, source_name) do
    on_exit(fn ->
      :sys.replace_state(AppHealth, fn state ->
        update_in(state.sources, &Map.delete(&1, {device_id, source_name}))
      end)
    end)
  end

  defp wait_until_state(pid, fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_state(pid, fun, deadline)
  end

  defp do_wait_until_state(pid, fun, deadline) do
    state = :sys.get_state(pid)

    if fun.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("state condition not met before timeout")
      else
        Process.sleep(25)
        do_wait_until_state(pid, fun, deadline)
      end
    end
  end

  defp listen_socket do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp perform_websocket_handshake(socket) do
    request = recv_http_request(socket)
    [_, key] = Regex.run(~r/^sec-websocket-key:\s*(.+)\r$/mi, request)

    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n"
      ])
  end

  defp recv_http_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      recv_http_request(socket, acc <> chunk)
    end
  end

  defp send_text_frame(socket, payload) do
    encoded = Jason.encode!(payload)
    send_raw_frame(socket, <<0x81, byte_size(encoded)>> <> encoded)
  end

  defp send_raw_frame(socket, frame) do
    :ok = :gen_tcp.send(socket, frame)
  end

  defp maybe_recv_client_frame(socket) do
    case :gen_tcp.recv(socket, 0, 200) do
      {:ok, _data} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
