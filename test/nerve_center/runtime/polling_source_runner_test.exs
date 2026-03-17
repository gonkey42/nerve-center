defmodule NerveCenter.Runtime.PollingSourceRunnerTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.PollingSourceRunner
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
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

  test "expected-offline sources remain unknown before the first successful poll" do
    device = test_device()
    source_name = :glances

    seed_app_health(device.id, source_name)
    seed_snapshot(device)
    start_supervised!({DeviceHub, device: device})

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

  defp test_device do
    id = :"phase3_test_laptop_#{System.unique_integer([:positive])}"

    %{
      id: id,
      label: "Zoidberg",
      hostname: "zoidberg",
      ip: "100.126.22.36",
      offline_expected: true
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
end
