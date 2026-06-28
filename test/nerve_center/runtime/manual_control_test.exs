defmodule NerveCenter.Runtime.ManualControlTest do
  use NerveCenter.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Persistence.DeviceEvent
  alias NerveCenter.Persistence.SourceProbe
  alias NerveCenter.Repo
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.ManualControl
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Topology

  @bridge_port 9567
  @forbidden_bridge_token "bridge-token-123456789012345678901234"
  @forbidden_supervisor_token "supervisor-token-should-not-leak"
  @forbidden_password "raw-nut-password-should-not-leak"
  @forbidden_authorization "Authorization: Bearer #{@forbidden_bridge_token}"
  @forbidden_traceback "Traceback fake bridge failure"
  @forbidden_sensitive_atom :"Authorization bridge-token-123456789012345678901234 supervisor-token-should-not-leak raw-nut-password-should-not-leak Traceback"
  @forbidden_body %{
    "error" => "Unauthorized",
    "token" => @forbidden_bridge_token,
    "supervisor_token" => @forbidden_supervisor_token,
    "password" => @forbidden_password,
    "Authorization" => "Bearer #{@forbidden_bridge_token}",
    "trace" => @forbidden_traceback
  }
  @forbidden_bridge_body """
  token=#{@forbidden_bridge_token}
  supervisor_token=#{@forbidden_supervisor_token}
  password=#{@forbidden_password}
  #{@forbidden_authorization}
  #{@forbidden_traceback}
  """

  defmodule FakeManualSource do
    use NerveCenter.Runtime.PollingSource

    @impl true
    def required_env, do: []
    @impl true
    def normal_interval_ms, do: 60_000
    @impl true
    def stale_after_ms, do: 180_000
    @impl true
    def probe(_context), do: {:ok, %{mode: "manual"}}
    @impl true
    def poll(%{source: %{test_pid: test_pid}}), do: Agent.get(test_pid, & &1)
    @impl true
    def normalize(raw, _context), do: {:ok, raw}
  end

  setup do
    clear_persistence_writer_queues()
    delete_manual_rows()

    previous_snapshot = SnapshotStore.snapshot(:daisy)
    previous_hub_state = current_hub_state(:daisy)
    previous_health = AppHealth.source_state(:daisy, :ha_supervisor)
    suspended_runner = suspend_source_runner(:daisy, :ha_supervisor)

    device = Topology.get_device!(:daisy)

    snapshot = %DeviceSnapshot{
      device_id: :daisy,
      label: "DAISY",
      status: :ok,
      updated_at: DateTime.utc_now(),
      offline_expected: false,
      metrics: %{},
      sources: %{}
    }

    seed_app_health(:daisy, :ha_supervisor)
    SnapshotStore.put(snapshot)
    seed_device_hub(device, snapshot)

    on_exit(fn ->
      stop_bridge_server()
      resume_source_runner(suspended_runner)
      clear_persistence_writer_queues()
      delete_manual_rows()

      if previous_snapshot do
        SnapshotStore.put(previous_snapshot)
      end

      restore_device_hub(:daisy, previous_hub_state)
      restore_app_health(:daisy, :ha_supervisor, previous_health)
    end)

    :ok
  end

  test "refresh_source publishes semantic error instead of forcing ok" do
    start_bridge_server({200, bridge_payload(addon_payload(%{"state" => "error"}))})

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(:daisy, :ha_supervisor))

    assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
    assert snapshot.status == :error
    assert snapshot.last_error == nil
    assert snapshot.data.summary.message == "Network UPS Tools add-on is error."

    assert_receive %SourceSnapshotUpdated{source_snapshot: published}, 1_000
    assert published.status == :error
  end

  test "refresh_source ignores runtime source overrides and uses compiled topology source" do
    start_bridge_server({200, bridge_payload(addon_payload(%{"state" => "error"}))})

    test_pid =
      {Agent, fn -> {:ok, %{status: :ok, data: %{summary: %{message: "override used"}}}} end}
      |> Supervisor.child_spec(id: {Agent, make_ref()})
      |> start_supervised!()

    Application.put_env(:nerve_center, :manual_control_source_overrides, %{
      {:daisy, :ha_supervisor} => %{
        name: :ha_supervisor,
        module: FakeManualSource,
        enabled: true,
        interval_ms: 60_000,
        test_pid: test_pid
      }
    })

    on_exit(fn -> Application.delete_env(:nerve_center, :manual_control_source_overrides) end)

    assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
    assert snapshot.status == :error
    assert snapshot.data.summary.message == "Network UPS Tools add-on is error."
  end

  test "refresh_source defaults missing status to ok" do
    with_fake_ha_supervisor_source({:ok, %{data: %{summary: %{message: "missing status"}}}}, fn ->
      assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
      assert snapshot.status == :ok
      assert snapshot.data.summary.message == "missing status"
    end)
  end

  test "refresh_source defaults nil status to ok" do
    with_fake_ha_supervisor_source(
      {:ok, %{status: nil, data: %{summary: %{message: "nil status"}}}},
      fn ->
        assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
        assert snapshot.status == :ok
        assert snapshot.data.summary.message == "nil status"
      end
    )
  end

  test "refresh_source preserves every allowed semantic status" do
    allowed_statuses = [:ok, :degraded, :error, :offline, :stale, :unknown]

    Enum.each(allowed_statuses, fn status ->
      assert_semantic_status(status)
    end)
  end

  test "refresh_source returns sanitized error tuple on callback error" do
    stop_bridge_server()

    log =
      capture_log(fn ->
        assert {:error, {:request, :failed}} =
                 ManualControl.refresh_source(:daisy, :ha_supervisor)
      end)

    assert_sanitized_everywhere(log)
  end

  test "refresh_source sanitizes sensitive atom callback errors" do
    cases = [
      {{:error, @forbidden_sensitive_atom}, {:manual_refresh_failed, :callback_error}},
      {{:error, {:request, @forbidden_sensitive_atom}}, {:request, :failed}}
    ]

    Enum.each(cases, fn {callback_return, expected_error} ->
      log =
        capture_log(fn ->
          with_fake_ha_supervisor_source(callback_return, fn ->
            assert {:error, ^expected_error} =
                     ManualControl.refresh_source(:daisy, :ha_supervisor)
          end)
        end)

      assert_sanitized(expected_error)
      assert_sanitized_everywhere(log)
    end)
  end

  test "refresh_source rejects invalid semantic status without publishing it" do
    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(:daisy, :ha_supervisor))

    with_fake_ha_supervisor_source(
      {:ok, %{status: :maintenance, data: %{summary: %{message: "bad status"}}}},
      fn ->
        assert {:error, {:invalid_callback_payload, :invalid_semantic_status}} =
                 ManualControl.refresh_source(:daisy, :ha_supervisor)
      end
    )

    refute_receive %SourceSnapshotUpdated{source_snapshot: %SourceSnapshot{status: :maintenance}},
                   100

    snapshot = SnapshotStore.snapshot(:daisy)
    refute sanitized_render(snapshot) =~ "maintenance"
    refute sanitized_render(snapshot) =~ "bad status"
    assert_sanitized_persistence()
  end

  test "refresh_source sanitizes exception messages containing forbidden bridge body strings" do
    log =
      capture_log(fn ->
        with_fake_ha_supervisor_source({:raise, @forbidden_bridge_body}, fn ->
          assert {:error, {:manual_refresh_failed, :exception}} =
                   ManualControl.refresh_source(:daisy, :ha_supervisor)
        end)
      end)

    assert_sanitized_everywhere(log)
  end

  test "refresh_source sanitizes invalid callback returns containing forbidden bridge body strings" do
    log =
      capture_log(fn ->
        with_fake_ha_supervisor_source({:invalid_callback_return, @forbidden_bridge_body}, fn ->
          assert {:error, {:invalid_callback_payload, :invalid_return}} =
                   ManualControl.refresh_source(:daisy, :ha_supervisor)
        end)
      end)

    assert_sanitized_everywhere(log)
  end

  test "refresh_source sanitizes raw auth and http tuples without raw bridge bodies" do
    real_bridge_cases = [
      {403, {:auth, 403, :manual_refresh_unauthorized}},
      {503, {:http, 503, :manual_refresh_http_error}}
    ]

    Enum.each(real_bridge_cases, fn {status, expected_error} ->
      start_bridge_server({status, %{"error" => @forbidden_bridge_body}})

      log =
        capture_log(fn ->
          assert {:error, ^expected_error} = ManualControl.refresh_source(:daisy, :ha_supervisor)
        end)

      assert_sanitized_everywhere(log)
    end)

    raw_callback_cases = [
      {{:error, {:auth, 403, @forbidden_bridge_body}},
       {:auth, 403, :manual_refresh_unauthorized}},
      {{:error, {:http, 503, @forbidden_bridge_body}}, {:http, 503, :manual_refresh_http_error}}
    ]

    Enum.each(raw_callback_cases, fn {callback_return, expected_error} ->
      log =
        capture_log(fn ->
          with_fake_ha_supervisor_source(callback_return, fn ->
            assert {:error, ^expected_error} =
                     ManualControl.refresh_source(:daisy, :ha_supervisor)
          end)
        end)

      assert_sanitized_everywhere(log)
    end)
  end

  test "manual refresh redacts forbidden bridge body on source failure" do
    start_bridge_server({401, @forbidden_body})

    log =
      capture_log(fn ->
        assert {:error, error} = ManualControl.refresh_source(:daisy, :ha_supervisor)
        assert error == {:auth, 401, :manual_refresh_unauthorized}
        assert_forbidden_absent(error)
      end)

    assert_forbidden_absent(log)
    assert_forbidden_absent(AppHealth.source_state(:daisy, :ha_supervisor))
    assert_forbidden_absent(SnapshotStore.snapshot(:daisy))
    assert_sanitized_persistence()
  end

  test "repeated ha supervisor manual refresh with stable problems does not enqueue problem events" do
    start_bridge_server({200, bridge_payload(addon_payload(%{"state" => "error"}))})

    assert {:ok, first_snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
    assert first_snapshot.status == :error

    assert {:ok, second_snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
    assert second_snapshot.status == :error

    wait_until(fn -> count_probes() >= 2 end)

    assert count_ha_supervisor_events() == 0
  end

  defp assert_semantic_status(status) when status in [:ok, :degraded, :error] do
    status
    |> bridge_payload_for_status()
    |> then(&start_bridge_server({200, &1}))

    assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
    assert snapshot.status == status
  end

  defp assert_semantic_status(status) when status in [:offline, :stale, :unknown] do
    with_fake_ha_supervisor_source(
      {:ok, %{status: status, data: %{summary: %{message: Atom.to_string(status)}}}},
      fn ->
        assert {:ok, snapshot} = ManualControl.refresh_source(:daisy, :ha_supervisor)
        assert snapshot.status == status
        assert snapshot.data.summary.message == Atom.to_string(status)
      end
    )
  end

  defp bridge_payload_for_status(:ok), do: bridge_payload(addon_payload(%{}))

  defp bridge_payload_for_status(:degraded),
    do: bridge_payload(addon_payload(%{}), %{"supported" => false})

  defp bridge_payload_for_status(:error),
    do: bridge_payload(addon_payload(%{"state" => "error"}))

  defp with_fake_ha_supervisor_source(callback_return, fun) do
    module = NerveCenter.Sources.Daisy.HASupervisorSource
    {^module, original_binary, original_filename} = :code.get_object_code(module)
    previous_conflict_option = Code.compiler_options().ignore_module_conflict

    try do
      Process.put(:manual_control_fake_source_response, callback_return)
      Code.compiler_options(ignore_module_conflict: true)
      :code.purge(module)
      :code.delete(module)
      Code.compile_quoted(fake_ha_supervisor_source_quote())
      fun.()
    after
      Process.delete(:manual_control_fake_source_response)
      :code.purge(module)
      :code.delete(module)
      {:module, ^module} = :code.load_binary(module, original_filename, original_binary)
      Code.compiler_options(ignore_module_conflict: previous_conflict_option)
    end
  end

  defp fake_ha_supervisor_source_quote do
    quote do
      defmodule NerveCenter.Sources.Daisy.HASupervisorSource do
        use NerveCenter.Runtime.PollingSource

        @impl true
        def required_env, do: []
        @impl true
        def normal_interval_ms, do: 60_000
        @impl true
        def stale_after_ms, do: 180_000
        @impl true
        def probe(_context), do: {:ok, %{mode: "manual"}}

        @impl true
        def poll(_context) do
          case Process.get(:manual_control_fake_source_response) do
            {:raise, message} -> raise message
            other -> other
          end
        end

        @impl true
        def normalize(raw, _context), do: {:ok, raw}
      end
    end
  end

  defp start_bridge_server(response) do
    stop_bridge_server()

    {:ok, listener} =
      :gen_tcp.listen(@bridge_port, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    task =
      Task.async(fn ->
        bridge_accept_loop(listener, response)
      end)

    Process.put(:manual_control_bridge_server, {listener, task})
  end

  defp stop_bridge_server do
    case Process.delete(:manual_control_bridge_server) do
      {listener, task} ->
        :gen_tcp.close(listener)
        Task.shutdown(task, :brutal_kill)

      _other ->
        :ok
    end
  end

  defp bridge_accept_loop(listener, response) do
    case :gen_tcp.accept(listener, 100) do
      {:ok, socket} ->
        _request = recv_http_request(socket)
        send_response(socket, response)
        :ok = :gen_tcp.close(socket)
        bridge_accept_loop(listener, response)

      {:error, :timeout} ->
        bridge_accept_loop(listener, response)

      {:error, :closed} ->
        :ok
    end
  end

  defp recv_http_request(socket), do: recv_http_request(socket, "")

  defp recv_http_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        request = acc <> chunk

        if String.contains?(request, "\r\n\r\n") do
          request
        else
          recv_http_request(socket, request)
        end

      {:error, _reason} ->
        acc
    end
  end

  defp send_response(socket, {status, body}) do
    payload = Jason.encode!(body)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(payload)}\r\n",
        "connection: close\r\n",
        "\r\n",
        payload
      ])
  end

  defp bridge_payload(addon, supervisor_overrides \\ %{}) do
    %{
      "observed_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "supervisor" =>
        %{
          "version" => "2026.06.2",
          "version_latest" => "2026.06.2",
          "update_available" => false,
          "healthy" => true,
          "supported" => true,
          "channel" => "stable"
        }
        |> Map.merge(supervisor_overrides),
      "addons" => [addon]
    }
  end

  defp addon_payload(overrides) do
    Map.merge(
      %{
        "slug" => "a0d7b954_nut",
        "name" => "Network UPS Tools",
        "state" => "started",
        "version" => "0.18.0",
        "version_latest" => "0.18.0",
        "update_available" => false,
        "available" => true,
        "boot" => "auto",
        "startup" => "system",
        "protected" => true,
        "network" => %{"3493/tcp" => 3493},
        "config_summary" => %{
          "mode" => "netserver",
          "shutdown_host" => false,
          "device_count" => 1,
          "users" => [
            %{"username_set" => true, "password_set" => true, "upsmon" => "primary"}
          ]
        },
        "config_warnings" => []
      },
      overrides
    )
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_status), do: "Error"

  defp delete_manual_rows do
    Repo.delete_all(
      from event in DeviceEvent,
        where: event.device_id == "daisy" and event.source == "ha_supervisor"
    )

    Repo.delete_all(
      from probe in SourceProbe,
        where: probe.device_id == "daisy" and probe.source == "ha_supervisor"
    )
  end

  defp seed_device_hub(device, snapshot) do
    case Registry.lookup(NerveCenter.Runtime.DeviceRegistry, device.id) do
      [{pid, _value}] ->
        :sys.replace_state(pid, &%{&1 | snapshot: snapshot})

      [] ->
        start_supervised!({DeviceHub, device: device})
    end
  end

  defp current_hub_state(device_id) do
    case Registry.lookup(NerveCenter.Runtime.DeviceRegistry, device_id) do
      [{pid, _value}] -> {:ok, pid, :sys.get_state(pid)}
      [] -> :missing
    end
  end

  defp restore_device_hub(_device_id, {:ok, pid, state}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn _current -> state end)
    end
  end

  defp restore_device_hub(_device_id, :missing), do: :ok

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

    restore_app_health(device_id, source_name, source_state)
  end

  defp restore_app_health(device_id, source_name, source_state) do
    :sys.replace_state(AppHealth, fn state ->
      %{state | sources: Map.put(state.sources, {device_id, source_name}, source_state)}
    end)
  end

  defp suspend_source_runner(device_id, source_name) do
    case :global.whereis_name({:device_tree, device_id}) do
      :undefined ->
        nil

      tree_pid ->
        tree_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {{_module, ^device_id, ^source_name}, pid, _type, _modules} when is_pid(pid) ->
            :sys.suspend(pid)
            pid

          _child ->
            nil
        end)
    end
  catch
    :exit, _reason -> nil
  end

  defp resume_source_runner(nil), do: :ok

  defp resume_source_runner(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      :sys.resume(pid)
    end
  catch
    :exit, _reason -> :ok
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

  defp count_probes do
    SourceProbe
    |> where([probe], probe.device_id == "daisy" and probe.source == "ha_supervisor")
    |> Repo.aggregate(:count, :id)
  end

  defp count_ha_supervisor_events do
    DeviceEvent
    |> where(
      [event],
      event.device_id == "daisy" and event.source == "ha_supervisor" and
        like(event.event_type, "ha_supervisor%")
    )
    |> Repo.aggregate(:count, :id)
  end

  defp assert_sanitized_everywhere(log) do
    assert_sanitized(log)
    assert_sanitized_persistence()
    assert_sanitized(SnapshotStore.snapshot(:daisy))
  end

  defp assert_sanitized_persistence do
    wait_until(fn ->
      PersistenceWriter
      |> :sys.get_state()
      |> then(&(&1.sample_count == 0 and &1.event_count == 0 and &1.probe_count == 0))
    end)

    rows =
      Repo.all(
        from event in DeviceEvent,
          where: event.device_id == "daisy" and event.source == "ha_supervisor"
      ) ++
        Repo.all(
          from probe in SourceProbe,
            where: probe.device_id == "daisy" and probe.source == "ha_supervisor"
        )

    assert_sanitized(rows)
  end

  defp assert_sanitized(term) do
    rendered = sanitized_render(term)

    for fragment <- forbidden_fragments() do
      refute rendered =~ fragment
    end
  end

  defp assert_forbidden_absent(term) do
    encoded = inspect(term, limit: :infinity, printable_limit: :infinity)

    for forbidden <- [
          @forbidden_bridge_token,
          @forbidden_supervisor_token,
          @forbidden_password,
          "Authorization",
          "Traceback"
        ] do
      refute encoded =~ forbidden
    end
  end

  defp sanitized_render(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp forbidden_fragments do
    [
      @forbidden_bridge_token,
      @forbidden_supervisor_token,
      @forbidden_password,
      @forbidden_authorization,
      @forbidden_traceback,
      "Authorization",
      "Traceback"
    ]
  end

  defp wait_until(fun, timeout_ms \\ 1_500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(25)
        do_wait_until(fun, deadline)
      end
    end
  end
end
