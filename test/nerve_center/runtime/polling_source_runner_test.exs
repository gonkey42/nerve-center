defmodule NerveCenter.Runtime.PollingSourceRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NerveCenter.Messages.AppHealthUpdated
  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.PollingSourceRunner
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Topology

  defmodule FakeOfflineAwareSource do
    use NerveCenter.Runtime.PollingSource

    @impl true
    def required_env, do: []

    @impl true
    def normal_interval_ms, do: 60_000

    @impl true
    def stale_after_ms, do: 180_000

    @impl true
    def probe(_context), do: {:ok, %{mode: "test"}}

    @impl true
    def poll(%{source: %{test_pid: test_pid}}) do
      Agent.get_and_update(test_pid, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, {:request, "no scripted response"}}, []}
      end)
    end

    @impl true
    def normalize(raw, _context) do
      cpu = raw[:cpu] || raw["cpu"] || 0.0

      {:ok,
       %{
         observed_at: DateTime.utc_now(),
         metrics: [%{metric: :cpu_util_ratio, value: cpu}],
         data: %{cpu: cpu}
       }}
    end
  end

  defmodule CrashySource do
    use NerveCenter.Runtime.PollingSource

    @impl true
    def required_env, do: []

    @impl true
    def normal_interval_ms, do: 60_000

    @impl true
    def stale_after_ms, do: 180_000

    @impl true
    def probe(_context), do: {:ok, %{mode: "test"}}

    @impl true
    def poll(%{source: %{test_pid: test_pid}}) do
      next_response =
        Agent.get_and_update(test_pid, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, {:request, "no scripted response"}}, []}
        end)

      case next_response do
        :raise -> raise "boom"
        other -> other
      end
    end

    @impl true
    def normalize(raw, _context) do
      cpu = raw[:cpu] || raw["cpu"] || 0.0

      {:ok,
       %{
         observed_at: DateTime.utc_now(),
         metrics: [%{metric: :cpu_util_ratio, value: cpu}],
         data: %{cpu: cpu}
       }}
    end
  end

  defmodule FakeSemanticSource do
    use NerveCenter.Runtime.PollingSource

    @impl true
    def required_env, do: []

    @impl true
    def normal_interval_ms, do: 60_000

    @impl true
    def stale_after_ms, do: 180_000

    @impl true
    def probe(_context), do: {:ok, %{mode: "semantic-test"}}

    @impl true
    def poll(%{source: %{test_pid: test_pid}}) do
      Agent.get_and_update(test_pid, fn
        [next | rest] -> {next, rest}
        [] -> {{:error, {:request, "no scripted response"}}, []}
      end)
    end

    @impl true
    def normalize(raw, _context), do: {:ok, raw}
  end

  test "expected-offline sources remain unknown before the first successful poll" do
    device = test_device()
    source_name = :glances

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses = start_supervised!({Agent, fn -> [{:error, {:request, "nxdomain"}}] end})

    start_supervised!(
      {PollingSourceRunner,
       module: FakeOfflineAwareSource,
       device: device,
       source: %{name: source_name, interval_ms: 60_000, test_pid: responses}}
    )

    assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
    assert source_snapshot.status == :unknown
    assert source_snapshot.backoff_ms == 300_000
    assert source_snapshot.ever_ok? == false

    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
    assert device_snapshot.status == :unknown
  end

  test "expected-offline sources transition to offline after a prior success" do
    device = test_device()
    source_name = :glances

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_supervised!({DeviceHub, device: device})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_supervised!({Agent, fn -> [{:ok, %{cpu: 0.25}}, {:error, {:request, "timeout"}}] end})

    runner =
      start_supervised!(
        {PollingSourceRunner,
         module: FakeOfflineAwareSource,
         device: device,
         source: %{name: source_name, interval_ms: 60_000, test_pid: responses}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: initial_snapshot}, 1_000
    assert initial_snapshot.status == :ok

    send(runner, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: offline_snapshot}, 1_000
    assert offline_snapshot.status == :offline
    assert offline_snapshot.backoff_ms == 300_000
    assert offline_snapshot.metrics[:cpu_util_ratio] == 0.25

    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
    assert device_snapshot.status == :ok

    assert_receive %DeviceSnapshotUpdated{snapshot: offline_device_snapshot}, 1_000
    assert offline_device_snapshot.status == :offline
  end

  test "poll callback crashes are converted into failure snapshots without killing the runner" do
    device = test_device()
    source_name = :glances

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_supervised!({DeviceHub, device: device})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_supervised!({Agent, fn -> [:raise, {:ok, %{cpu: 0.42}}] end})

    runner =
      start_supervised!(
        {PollingSourceRunner,
         module: CrashySource,
         device: device,
         source: %{name: source_name, interval_ms: 60_000, test_pid: responses}}
      )

    assert_receive %SourceSnapshotUpdated{source_snapshot: failed_snapshot}, 1_000
    assert failed_snapshot.status == :unknown
    assert failed_snapshot.last_error =~ "callback_crash"
    assert Process.alive?(runner)

    send(runner, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: recovered_snapshot}, 1_000
    assert recovered_snapshot.status == :ok
    assert recovered_snapshot.metrics[:cpu_util_ratio] == 0.42
    assert Process.alive?(runner)
  end

  test "logs actionable failure and recovery messages" do
    device = test_device(%{offline_expected: false})
    source_name = :glances
    previous_level = Application.get_env(:logger, :level, :warning)

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_supervised!({DeviceHub, device: device})

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_supervised!({Agent, fn -> [{:error, {:request, "timeout"}}, {:ok, %{cpu: 0.31}}] end})

    log =
      capture_log([level: :info], fn ->
        runner =
          start_supervised!(
            {PollingSourceRunner,
             module: FakeOfflineAwareSource,
             device: device,
             source: %{name: source_name, interval_ms: 60_000, test_pid: responses}}
          )

        assert_receive %SourceSnapshotUpdated{source_snapshot: failed_snapshot}, 1_000
        assert failed_snapshot.status == :unknown

        send(runner, :poll)

        assert_receive %SourceSnapshotUpdated{source_snapshot: recovered_snapshot}, 1_000
        assert recovered_snapshot.status == :ok
      end)

    assert log =~ "polling source #{device.id}/#{source_name} entered unknown"
    assert log =~ "reason={:request, \"timeout\"}"
    assert log =~ "recovered after 1 failures"
  end

  test "successful payload without status still publishes ok" do
    device = test_device()
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_supervised!({DeviceHub, device: device})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses = start_script([{:ok, %{data: %{summary: %{message: "missing status"}}}}])

    start_semantic_runner(device, source_name, responses)

    assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
    assert source_snapshot.status == :ok
    assert source_snapshot.data.summary.message == "missing status"

    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
    assert device_snapshot.sources[source_name].status == :ok
    assert SnapshotStore.snapshot(device.id).sources[source_name].status == :ok
  end

  test "successful payload with nil status still publishes ok" do
    device = test_device()
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses = start_script([{:ok, %{status: nil, data: %{summary: %{message: "nil status"}}}}])

    start_semantic_runner(device, source_name, responses)

    assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
    assert source_snapshot.status == :ok
    assert source_snapshot.data.summary.message == "nil status"

    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
    assert device_snapshot.sources[source_name].status == :ok
    assert SnapshotStore.snapshot(device.id).sources[source_name].status == :ok
  end

  test "successful payload preserves every allowed semantic status" do
    allowed_statuses = [:ok, :degraded, :error, :offline, :stale, :unknown]

    Enum.each(allowed_statuses, fn status ->
      device = test_device()
      source_name = :ha_supervisor

      seed_app_health(device.id, source_name)
      seed_snapshot(device)
      start_device_hub(device)

      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
      Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

      responses =
        start_script([
          {:ok,
           %{
             status: status,
             data: %{summary: %{message: Atom.to_string(status)}}
           }}
        ])

      start_semantic_runner(device, source_name, responses)

      assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
      assert source_snapshot.status == status
      assert source_snapshot.data.summary.message == Atom.to_string(status)

      assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
      assert device_snapshot.sources[source_name].status == status
      assert SnapshotStore.snapshot(device.id).sources[source_name].status == status
    end)
  end

  test "invalid semantic status is rejected as sanitized callback payload error" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok,
         %{
           status: :maintenance,
           metrics: [%{metric: :cpu_util_ratio, value: 0.99}],
           events: [%{event_type: :invalid_semantic_status, message: "bad event"}],
           private: %{secret: "invalid private"},
           data: %{summary: %{message: "bad status"}}
         }}
      ])

    clear_persistence_writer_queues()
    on_exit(&clear_persistence_writer_queues/0)

    log =
      capture_log([level: :warning], fn ->
        runner = start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
        assert source_snapshot.status == :unknown
        refute source_snapshot.status == :maintenance

        assert source_snapshot.last_error ==
                 "{:invalid_callback_payload, :invalid_semantic_status}"

        refute source_snapshot.last_error =~ "maintenance"
        refute source_snapshot.last_error =~ "bad status"
        assert source_snapshot.data == %{}
        assert source_snapshot.metrics == %{}
        assert :sys.get_state(runner).private == %{}

        assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
        refute device_snapshot.sources[source_name].status == :maintenance
        assert SnapshotStore.snapshot(device.id).sources[source_name].status == :unknown

        assert_receive %AppHealthUpdated{}, 1_000
      end)

    refute log =~ "maintenance"
    refute log =~ "bad status"
    refute log =~ "bad event"
    refute log =~ "invalid private"

    health = AppHealth.source_state(device.id, source_name)
    assert health.consecutive_failures == 1
    assert health.last_error == "{:invalid_callback_payload, :invalid_semantic_status}"

    writer_state = :sys.get_state(PersistenceWriter)
    assert writer_state.sample_count == 0
    assert writer_state.event_count == 0
  end

  test "false semantic status is rejected without publishing or persisting invalid payload data" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok,
         %{
           status: false,
           metrics: [%{metric: :cpu_util_ratio, value: 0.77}],
           events: [%{event_type: :invalid_false_status, message: "false-status event"}],
           private: %{token: "false-status private"},
           data: %{summary: %{message: "false-status data"}}
         }}
      ])

    clear_persistence_writer_queues()
    on_exit(&clear_persistence_writer_queues/0)

    log =
      capture_log([level: :warning], fn ->
        runner = start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
        assert source_snapshot.status == :unknown
        refute source_snapshot.status == false

        assert source_snapshot.last_error ==
                 "{:invalid_callback_payload, :invalid_semantic_status}"

        refute source_snapshot.last_error =~ "false-status"
        assert source_snapshot.data == %{}
        assert source_snapshot.metrics == %{}
        assert :sys.get_state(runner).private == %{}

        assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000
        refute device_snapshot.sources[source_name].status == false
        assert SnapshotStore.snapshot(device.id).sources[source_name].status == :unknown

        assert_receive %AppHealthUpdated{}, 1_000
      end)

    refute log =~ "false-status"

    health = AppHealth.source_state(device.id, source_name)
    assert health.consecutive_failures == 1
    assert health.last_error == "{:invalid_callback_payload, :invalid_semantic_status}"

    writer_state = :sys.get_state(PersistenceWriter)
    assert writer_state.sample_count == 0
    assert writer_state.event_count == 0
  end

  test "successful semantic error publishes error without source failure" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok,
         %{
           status: :error,
           data: %{summary: %{message: "Network UPS Tools add-on is error."}}
         }}
      ])

    start_semantic_runner(device, source_name, responses)

    assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
    assert source_snapshot.status == :error
    assert source_snapshot.last_error == nil
    assert source_snapshot.last_error_at == nil
    assert source_snapshot.data.summary.message == "Network UPS Tools add-on is error."

    assert_receive %AppHealthUpdated{}, 1_000
    health = AppHealth.source_state(device.id, :ha_supervisor)
    assert health.consecutive_failures == 0
    assert health.backoff_ms == 0
    assert health.last_error == nil
  end

  test "successful semantic degraded degrades a device with otherwise ok sources" do
    device = test_device(%{offline_expected: false})

    seed_app_health(device.id, :ha_rest_probe)
    seed_app_health(device.id, :ha_supervisor)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_rest_probe))
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, :ha_supervisor))

    ok_responses = start_script([{:ok, %{status: :ok, data: %{summary: %{message: "ok"}}}}])

    degraded_responses =
      start_script([
        {:ok, %{status: :degraded, data: %{summary: %{message: "degraded"}}}}
      ])

    start_semantic_runner(device, :ha_rest_probe, ok_responses)
    assert_receive %SourceSnapshotUpdated{source: :ha_rest_probe}, 1_000
    assert_receive %DeviceSnapshotUpdated{snapshot: %{status: :ok}}, 1_000

    start_semantic_runner(device, :ha_supervisor, degraded_responses)
    assert_receive %SourceSnapshotUpdated{source: :ha_supervisor}, 1_000
    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000

    assert device_snapshot.status == :degraded
    assert device_snapshot.sources.ha_rest_probe.status == :ok
    assert device_snapshot.sources.ha_supervisor.status == :degraded
  end

  test "daisy device degrades when ha supervisor is semantic error while ha rest and websocket are ok" do
    device =
      test_device(%{
        id: :"daisy_semantic_#{System.unique_integer([:positive])}",
        label: "Daisy",
        hostname: "daisy",
        offline_expected: false
      })

    source_names = [:ha_rest_probe, :ha_web_socket, :ha_supervisor]

    Enum.each(source_names, &seed_app_health(device.id, &1))
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.device_topic(device.id))

    Enum.each(
      source_names,
      &Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, &1))
    )

    ha_rest_responses =
      start_script([{:ok, %{status: :ok, data: %{summary: %{message: "rest ok"}}}}])

    websocket_responses =
      start_script([{:ok, %{status: :ok, data: %{summary: %{message: "stream ok"}}}}])

    supervisor_responses =
      start_script([
        {:ok, %{status: :error, data: %{summary: %{message: "supervisor error"}}}}
      ])

    start_semantic_runner(device, :ha_rest_probe, ha_rest_responses)
    assert_receive %SourceSnapshotUpdated{source: :ha_rest_probe}, 1_000
    assert_receive %DeviceSnapshotUpdated{snapshot: %{status: :ok}}, 1_000

    start_semantic_runner(device, :ha_web_socket, websocket_responses)
    assert_receive %SourceSnapshotUpdated{source: :ha_web_socket}, 1_000
    assert_receive %DeviceSnapshotUpdated{snapshot: %{status: :ok}}, 1_000

    start_semantic_runner(device, :ha_supervisor, supervisor_responses)
    assert_receive %SourceSnapshotUpdated{source: :ha_supervisor}, 1_000
    assert_receive %DeviceSnapshotUpdated{snapshot: device_snapshot}, 1_000

    assert device_snapshot.status == :degraded
    refute device_snapshot.status == :offline
    assert device_snapshot.sources.ha_rest_probe.status == :ok
    assert device_snapshot.sources.ha_web_socket.status == :ok
    assert device_snapshot.sources.ha_supervisor.status == :error
  end

  test "semantic error does not populate last_error" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.app_health_topic())
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok,
         %{
           status: :error,
           data: %{summary: %{message: "semantic subject error"}}
         }}
      ])

    start_semantic_runner(device, source_name, responses)

    assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
    assert source_snapshot.status == :error
    assert source_snapshot.last_error == nil
    assert source_snapshot.last_error_at == nil

    assert_receive %AppHealthUpdated{}, 1_000
    health = AppHealth.source_state(device.id, source_name)
    assert health.last_error == nil
    assert health.last_error_at == nil
  end

  test "repeated semantic error does not log repeated recovered messages" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor
    previous_level = Application.get_env(:logger, :level, :warning)

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok, %{status: :error, data: %{summary: %{message: "first semantic error"}}}},
        {:ok, %{status: :error, data: %{summary: %{message: "second semantic error"}}}}
      ])

    log =
      capture_log([level: :info], fn ->
        runner = start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: first_snapshot}, 1_000
        assert first_snapshot.status == :error

        send(runner, :poll)

        assert_receive %SourceSnapshotUpdated{source_snapshot: second_snapshot}, 1_000
        assert second_snapshot.status == :error
      end)

    refute log =~ "communication recovered"
    refute log =~ "semantic status recovered to ok"
    refute log =~ "recovered after"
  end

  test "transport failure followed by semantic error logs communication recovery without semantic recovery" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor
    previous_level = Application.get_env(:logger, :level, :warning)

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:error, {:request, "timeout"}},
        {:ok, %{status: :error, data: %{summary: %{message: "semantic error"}}}}
      ])

    log =
      capture_log([level: :info], fn ->
        runner = start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: failed_snapshot}, 1_000
        assert failed_snapshot.status == :unknown

        send(runner, :poll)

        assert_receive %SourceSnapshotUpdated{source_snapshot: recovered_snapshot}, 1_000
        assert recovered_snapshot.status == :error
      end)

    assert log =~ "communication recovered after 1 failures semantic_status=error"
    refute log =~ "semantic status recovered to ok"
  end

  test "semantic recovery logs only after previous successful semantic non-ok status recovers to ok" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor
    previous_level = Application.get_env(:logger, :level, :warning)

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_device_hub(device)

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok, %{status: :degraded, data: %{summary: %{message: "degraded"}}}},
        {:ok, %{status: :ok, data: %{summary: %{message: "ok"}}}},
        {:ok, %{status: :ok, data: %{summary: %{message: "still ok"}}}}
      ])

    log =
      capture_log([level: :info], fn ->
        runner = start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: degraded_snapshot}, 1_000
        assert degraded_snapshot.status == :degraded

        send(runner, :poll)

        assert_receive %SourceSnapshotUpdated{source_snapshot: ok_snapshot}, 1_000
        assert ok_snapshot.status == :ok

        send(runner, :poll)

        assert_receive %SourceSnapshotUpdated{source_snapshot: still_ok_snapshot}, 1_000
        assert still_ok_snapshot.status == :ok
      end)

    assert count_occurrences(log, "semantic status recovered to ok") == 1
    refute log =~ "communication recovered"
  end

  test "semantic recovery after restart logs from stored successful non-ok semantic status" do
    device = test_device(%{offline_expected: false})
    source_name = :ha_supervisor
    previous_level = Application.get_env(:logger, :level, :warning)
    observed_at = DateTime.utc_now()

    seed_app_health(device.id, source_name)

    seed_snapshot(device, %{
      source_name => %SourceSnapshot{
        device_id: device.id,
        source: source_name,
        status: :degraded,
        observed_at: observed_at,
        last_ok_at: observed_at,
        last_error_at: nil,
        last_error: nil,
        probe_data: %{ok: true, data: %{mode: "semantic-test"}},
        consecutive_failures: 0,
        backoff_ms: 0,
        ever_ok?: true,
        metrics: %{},
        data: %{summary: %{message: "stored degraded"}}
      }
    })

    start_device_hub(device)

    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(device.id, source_name))

    responses =
      start_script([
        {:ok, %{status: :ok, data: %{summary: %{message: "recovered after restart"}}}}
      ])

    log =
      capture_log([level: :info], fn ->
        start_semantic_runner(device, source_name, responses)

        assert_receive %SourceSnapshotUpdated{source_snapshot: source_snapshot}, 1_000
        assert source_snapshot.status == :ok
        assert source_snapshot.data.summary.message == "recovered after restart"
      end)

    assert log =~ "semantic status recovered to ok"
    refute log =~ "communication recovered"
  end

  defp test_device(overrides \\ %{}) do
    id = Map.get(overrides, :id, :"phase3_test_laptop_#{System.unique_integer([:positive])}")

    Map.merge(
      %{
        id: id,
        label: "Zoidberg",
        hostname: "zoidberg",
        ip: "100.126.22.36",
        offline_expected: true
      },
      overrides
    )
  end

  defp seed_snapshot(device, sources \\ %{}) do
    SnapshotStore.put(%DeviceSnapshot{
      device_id: device.id,
      label: device.label,
      status: :unknown,
      updated_at: nil,
      offline_expected: device.offline_expected,
      metrics: %{},
      sources: sources
    })
  end

  defp seed_app_health(device_id, source_name) do
    source_state = %{
      device_id: device_id,
      source: source_name,
      last_ok_at: nil,
      consecutive_failures: 0,
      backoff_ms: 0,
      last_error_at: nil,
      last_error: nil
    }

    :sys.replace_state(AppHealth, fn state ->
      %{state | sources: Map.put(state.sources, {device_id, source_name}, source_state)}
    end)

    on_exit(fn ->
      :sys.replace_state(AppHealth, fn state ->
        update_in(state.sources, &Map.delete(&1, {device_id, source_name}))
      end)
    end)
  end

  defp start_semantic_runner(device, source_name, responses) do
    start_supervised!(
      {PollingSourceRunner,
       module: FakeSemanticSource,
       device: device,
       source: %{name: source_name, interval_ms: 60_000, test_pid: responses}}
    )
  end

  defp start_device_hub(device) do
    {DeviceHub, device: device}
    |> Supervisor.child_spec(id: {DeviceHub, device.id})
    |> start_supervised!()
  end

  defp start_script(responses) do
    {Agent, fn -> responses end}
    |> Supervisor.child_spec(id: {Agent, make_ref()})
    |> start_supervised!()
  end

  defp clear_persistence_writer_queues do
    :sys.replace_state(PersistenceWriter, fn state ->
      %{
        state
        | samples: [],
          sample_count: 0,
          events: [],
          event_count: 0,
          probes: [],
          probe_count: 0
      }
    end)
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
