defmodule NerveCenter.Sources.Daisy.HARestProbeTest do
  use NerveCenter.DataCase, async: false

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Persistence.SourceProbe
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Sources.Daisy.HARestProbe
  alias NerveCenter.Topology

  setup do
    previous = System.get_env("HA_TOKEN")
    System.put_env("HA_TOKEN", "test-ha-token")

    Repo.delete_all(SourceProbe)

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("HA_TOKEN")
      else
        System.put_env("HA_TOKEN", previous)
      end
    end)

    :ok
  end

  test "re-probes after boot instead of freezing the source state at startup" do
    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, config_payload("2026.3.2", "RUNNING")},
             {:ok, config_payload("2026.3.3", "RUNNING")}
           ]
         end}
      )

    {listener, port} = listen_socket()

    server =
      Task.async(fn ->
        serve_requests(listener, script, 2)
      end)

    device = test_device(port)
    seed_snapshot(device)
    clear_app_health_source_on_exit(device.id, :ha_rest_probe)

    start_supervised!({DeviceHub, device: device})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_rest_probe))

    probe =
      start_supervised!(
        {HARestProbe, device: device, source: %{name: :ha_rest_probe, interval_ms: 300_000}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: first_snapshot}, 1_000
    assert first_snapshot.status == :ok
    assert first_snapshot.data.version == "2026.3.2"

    wait_until(fn ->
      count_probes(device.id, :ha_rest_probe) == 1
    end)

    send(probe, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: second_snapshot}, 1_000
    assert second_snapshot.status == :ok
    assert second_snapshot.data.version == "2026.3.3"
    assert DateTime.compare(second_snapshot.observed_at, first_snapshot.observed_at) == :gt

    wait_until(fn ->
      count_probes(device.id, :ha_rest_probe) == 2
    end)

    assert AppHealth.source_state(device.id, :ha_rest_probe).last_ok_at ==
             second_snapshot.last_ok_at

    Task.await(server)
  end

  test "auth failures back off and recover on a later probe" do
    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:auth, 401, %{"message" => "expired token"}},
             {:ok, config_payload("2026.3.4", "RUNNING")}
           ]
         end}
      )

    {listener, port} = listen_socket()

    server =
      Task.async(fn ->
        serve_requests(listener, script, 2)
      end)

    device = test_device(port)
    seed_snapshot(device)
    clear_app_health_source_on_exit(device.id, :ha_rest_probe)

    start_supervised!({DeviceHub, device: device})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_rest_probe))

    probe =
      start_supervised!(
        {HARestProbe, device: device, source: %{name: :ha_rest_probe, interval_ms: 300_000}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: failed_snapshot}, 1_000
    assert failed_snapshot.status == :unknown
    assert failed_snapshot.backoff_ms == 60_000
    assert failed_snapshot.data.connected? == false
    assert failed_snapshot.last_error =~ "expired token"

    send(probe, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: recovered_snapshot}, 1_000
    assert recovered_snapshot.status == :ok
    assert recovered_snapshot.backoff_ms == 0
    assert recovered_snapshot.data.version == "2026.3.4"
    assert recovered_snapshot.data.connected?

    health = AppHealth.source_state(device.id, :ha_rest_probe)
    assert health.consecutive_failures == 0
    assert health.backoff_ms == 0
    assert health.last_error == nil

    Task.await(server)
  end

  defp test_device(port) do
    %{
      id: :"ha_rest_probe_test_#{System.unique_integer([:positive])}",
      label: "HA REST Probe Test",
      hostname: "daisy",
      ip: "127.0.0.1",
      offline_expected: false,
      home_assistant_base_url: "http://127.0.0.1:#{port}"
    }
  end

  defp seed_snapshot(device) do
    SnapshotStore.put(%DeviceSnapshot{
      device_id: device.id,
      label: device.label,
      status: :unknown,
      updated_at: nil,
      offline_expected: device.offline_expected,
      metrics: %{},
      sources: %{}
    })
  end

  defp clear_app_health_source_on_exit(device_id, source_name) do
    on_exit(fn ->
      :sys.replace_state(AppHealth, fn state ->
        update_in(state.sources, &Map.delete(&1, {device_id, source_name}))
      end)
    end)
  end

  defp count_probes(device_id, source_name) do
    device_id = Atom.to_string(device_id)
    source_name = Atom.to_string(source_name)

    SourceProbe
    |> where([probe], probe.device_id == ^device_id and probe.source == ^source_name)
    |> Repo.aggregate(:count, :id)
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(25)
        do_wait_until(fun, deadline)
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

  defp serve_requests(listener, script, request_count) do
    Enum.each(1..request_count, fn _ ->
      {:ok, socket} = :gen_tcp.accept(listener)
      request = recv_http_request(socket)

      assert String.contains?(
               String.downcase(request),
               "authorization: bearer test-ha-token"
             )

      response =
        Agent.get_and_update(script, fn
          [next | rest] -> {next, rest}
          [] -> flunk("no scripted HTTP response available")
        end)

      send_response(socket, response)
      :gen_tcp.close(socket)
    end)

    :gen_tcp.close(listener)
  end

  defp recv_http_request(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      recv_http_request(socket, acc <> chunk)
    end
  end

  defp send_response(socket, {:ok, body}) do
    encoded = Jason.encode!(body)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(encoded)),
        "\r\n\r\n",
        encoded
      ])
  end

  defp send_response(socket, {:auth, status, body}) do
    encoded = Jason.encode!(body)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 ",
        Integer.to_string(status),
        " Unauthorized\r\n",
        "content-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(encoded)),
        "\r\n\r\n",
        encoded
      ])
  end

  defp config_payload(version, state) do
    %{
      "location_name" => "Home",
      "version" => version,
      "state" => state,
      "time_zone" => "America/Detroit",
      "unit_system" => %{"temperature" => "F"},
      "components" => Enum.map(1..5, &"component_#{&1}")
    }
  end
end
