defmodule NerveCenterWeb.DetailLiveTest do
  use NerveCenterWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.PollingSourceRunner
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Sources.Daisy.HASupervisorSource
  alias NerveCenter.Topology

  @bridge_token "test-daisy-supervisor-bridge-token-123456"
  @forbidden_bridge_token "bridge-token-123456789012345678901234"
  @forbidden_supervisor_token "supervisor-token-should-not-leak"
  @forbidden_password "raw-nut-password-should-not-leak"
  @forbidden_body %{
    "error" => "Unauthorized",
    "token" => @forbidden_bridge_token,
    "supervisor_token" => @forbidden_supervisor_token,
    "password" => @forbidden_password,
    "Authorization" => "Bearer #{@forbidden_bridge_token}",
    "trace" => "Traceback fake bridge failure"
  }

  test "device detail renders for phase 1 devices", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/hal9000")

    assert html =~ "HAL9000"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for ups", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/ups")

    assert html =~ "UPS"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for rosie", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/rosie")

    assert html =~ "ROSIE"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for daisy", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/daisy")

    assert html =~ "DAISY"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for stig", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/stig")

    assert html =~ "Stig"
    assert html =~ "Current Metrics"
  end

  test "device detail renders for zoidberg", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/zoidberg")

    assert html =~ "Zoidberg"
    assert html =~ "Current Metrics"
  end

  test "source detail renders for the kitt pihole source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/kitt/pihole")

    assert html =~ "KITT / Pi-hole"
    assert html =~ "Health State"
  end

  test "source detail renders for the daisy websocket source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_web_socket")

    assert html =~ "DAISY / Home Assistant Stream"
    assert html =~ "Health State"
  end

  test "source detail renders daisy ha supervisor source with sanitized addon table", %{
    conn: conn
  } do
    now = DateTime.utc_now()

    seed_daisy_supervisor(
      now,
      %{
        "summary" => %{
          "status" => "error",
          "problem_count" => 2,
          "required_unhealthy_count" => 1,
          "optional_unhealthy_count" => 0,
          "update_available_count" => 1,
          "message" => "Network UPS Tools has nut_username_blank and nut_password_blank."
        },
        "supervisor" => %{
          "healthy" => true,
          "supported" => true,
          "token" => "supervisor-token-should-not-leak"
        },
        "addons" => [
          %{
            "slug" => "a0d7b954_nut",
            "label" => "Network UPS Tools",
            "name" => "Network UPS Tools",
            "required" => true,
            "state" => "stopped",
            "status" => "error",
            "version" => "0.18.0",
            "version_latest" => "0.19.0",
            "update_available" => true,
            "config_summary" => %{"password" => "raw-nut-password-should-not-leak"},
            "config_warnings" => [
              %{
                "code" => "nut_username_blank",
                "detail" => "supervisor-token-should-not-leak"
              },
              %{
                "code" => "nut_password_blank",
                "detail" => "raw-nut-password-should-not-leak"
              }
            ]
          }
        ]
      }
    )

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "Network UPS Tools"
    assert html =~ "a0d7b954_nut"
    assert html =~ "stopped"
    assert html =~ "0.18.0"
    assert html =~ "0.19.0"
    assert html =~ "Config Warnings"
    assert html =~ "nut_username_blank"
    assert html =~ "nut_password_blank"
    refute html =~ "raw-nut-password-should-not-leak"
    refute html =~ "supervisor-token-should-not-leak"
  end

  test "source detail renders safe ha supervisor fallback when addons are missing", %{conn: conn} do
    now = DateTime.utc_now()

    seed_daisy_supervisor(now, %{
      "summary" => %{"message" => "supervisor-token-should-not-leak"},
      "supervisor" => %{"token" => "supervisor-token-should-not-leak"},
      "config_summary" => %{"password" => "raw-nut-password-should-not-leak"},
      "config_warnings" => [
        %{
          "code" => "nut_username_blank",
          "detail" => "raw-nut-password-should-not-leak"
        }
      ]
    })

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "Supervisor add-on data unavailable."
    refute html =~ "<pre"
    refute html =~ "nut_username_blank"
    refute html =~ "raw-nut-password-should-not-leak"
    refute html =~ "supervisor-token-should-not-leak"
  end

  test "source detail renders safe ha supervisor fallback when addons are malformed", %{
    conn: conn
  } do
    now = DateTime.utc_now()

    seed_daisy_supervisor(now, %{
      "summary" => %{"message" => "raw-nut-password-should-not-leak"},
      "supervisor" => %{"token" => "supervisor-token-should-not-leak"},
      "addons" => %{
        "a0d7b954_nut" => %{
          "label" => "Network UPS Tools",
          "config_summary" => %{"password" => "raw-nut-password-should-not-leak"}
        }
      }
    })

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "Supervisor add-on data unavailable."
    refute html =~ "<pre"
    refute html =~ "Network UPS Tools"
    refute html =~ "raw-nut-password-should-not-leak"
    refute html =~ "supervisor-token-should-not-leak"
  end

  test "source detail safely degrades non-scalar ha supervisor addon fields", %{conn: conn} do
    now = DateTime.utc_now()

    seed_daisy_supervisor(now, %{
      "summary" => %{"message" => ["raw-nut-password-should-not-leak"]},
      "addons" => [
        %{
          "slug" => "a0d7b954_nut",
          "label" => %{"secret" => "raw-nut-password-should-not-leak"},
          "name" => ["supervisor-token-should-not-leak"],
          "required" => %{"bad" => true},
          "state" => %{"bad" => "supervisor-token-should-not-leak"},
          "version" => ["0.18.0"],
          "version_latest" => %{"bad" => "0.19.0"},
          "update_available" => %{"bad" => true},
          "config_warnings" => [
            %{"code" => %{"bad" => "supervisor-token-should-not-leak"}},
            %{"code" => "nut_password_blank"}
          ]
        }
      ]
    })

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "a0d7b954_nut"
    assert html =~ "nut_password_blank"
    refute html =~ "raw-nut-password-should-not-leak"
    refute html =~ "supervisor-token-should-not-leak"
  end

  test "source detail html does not render forbidden bridge body strings after failure", %{
    conn: conn
  } do
    clear_persistence_writer_queues()
    set_bridge_token()

    {listener, port} = listen_socket()

    server =
      serve_requests(listener, 1, fn socket, _request ->
        send_response(socket, {401, @forbidden_body})
      end)

    device = daisy_device(port)
    prepare_daisy_runtime(device)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(:daisy, :ha_supervisor))

    log =
      capture_log([level: :warning], fn ->
        start_supervised!(
          {PollingSourceRunner,
           module: HASupervisorSource, device: device, source: daisy_supervisor_source()}
        )

        assert_receive %SourceSnapshotUpdated{source_snapshot: failed_snapshot}, 1_000
        assert failed_snapshot.status == :unknown
        assert failed_snapshot.last_error == "{:auth, 401, :supervisor_bridge_unauthorized}"
        assert_forbidden_absent(failed_snapshot.last_error)
        assert_forbidden_absent(failed_snapshot.probe_data)
        assert_forbidden_absent(failed_snapshot.data)
      end)

    wait_until(fn ->
      AppHealth.source_state(:daisy, :ha_supervisor).last_error ==
        "{:auth, 401, :supervisor_bridge_unauthorized}"
    end)

    {:ok, _view, html} = live(conn, ~p"/sources/daisy/ha_supervisor")

    assert html =~ "DAISY / HA Supervisor"
    assert html =~ "supervisor_bridge_unauthorized"
    assert_forbidden_absent(html)
    assert_forbidden_absent(log)
    assert_forbidden_absent(SnapshotStore.snapshot(:daisy))
    assert_forbidden_absent(AppHealth.source_state(:daisy, :ha_supervisor))

    Task.await(server)
  end

  test "source detail renders for the stig unifi source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/stig/unifi")

    assert html =~ "Stig / UniFi"
    assert html =~ "Health State"
  end

  test "source detail renders for the zoidberg glances source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sources/zoidberg/glances")

    assert html =~ "Zoidberg / Glances"
    assert html =~ "Health State"
  end

  test "dashboard and source list use friendly source names", %{conn: conn} do
    {:ok, _dashboard, dashboard_html} = live(conn, ~p"/")
    {:ok, _sources, sources_html} = live(conn, ~p"/sources")

    assert dashboard_html =~ "Local Metrics: "
    refute dashboard_html =~ ">local_metrics: "

    assert sources_html =~ "Home Assistant REST"
    assert sources_html =~ "Home Assistant Stream"
    assert sources_html =~ "Frigate Preview"
    refute sources_html =~ ">ha_rest_probe<"
    refute sources_html =~ ">ha_web_socket<"
    refute sources_html =~ ">frigate_preview<"
  end

  test "device detail uses friendly source names and hides raw module names", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/hal9000")

    assert html =~ "Local Metrics"
    assert html =~ "Launch Agents"
    refute html =~ ">local_metrics<"
    refute html =~ "NerveCenter.Sources.HAL9000.LocalMetricsSource"
  end

  defp ok_source(device_id, source, now) do
    %SourceSnapshot{
      device_id: device_id,
      source: source,
      status: :ok,
      observed_at: now,
      last_ok_at: now,
      last_error_at: nil,
      last_error: nil,
      probe_data: %{ok: true},
      consecutive_failures: 0,
      backoff_ms: 0,
      ever_ok?: true,
      metrics: %{},
      data: %{}
    }
  end

  defp seed_daisy_supervisor(now, supervisor_data) do
    previous = SnapshotStore.snapshot(:daisy)

    on_exit(fn -> SnapshotStore.put(previous) end)

    SnapshotStore.put(%DeviceSnapshot{
      device_id: :daisy,
      label: "DAISY",
      status: :degraded,
      updated_at: now,
      offline_expected: false,
      metrics: %{},
      sources: %{
        ha_web_socket: ok_source(:daisy, :ha_web_socket, now),
        ha_rest_probe: ok_source(:daisy, :ha_rest_probe, now),
        ha_supervisor: %SourceSnapshot{
          device_id: :daisy,
          source: :ha_supervisor,
          status: :error,
          observed_at: now,
          last_ok_at: now,
          last_error_at: nil,
          last_error: nil,
          probe_data: %{ok: true},
          consecutive_failures: 0,
          backoff_ms: 0,
          ever_ok?: true,
          metrics: %{},
          data: supervisor_data
        }
      }
    })
  end

  defp daisy_device(port) do
    :daisy
    |> Topology.get_device!()
    |> Map.put(:supervisor_bridge_base_url, "http://127.0.0.1:#{port}")
  end

  defp daisy_supervisor_source do
    Topology.get_source!(:daisy, :ha_supervisor)
  end

  defp prepare_daisy_runtime(device) do
    previous_snapshot = SnapshotStore.snapshot(:daisy)
    previous_hub_state = current_hub_state(:daisy)
    previous_health = AppHealth.source_state(:daisy, :ha_supervisor)
    suspended_runner = suspend_source_runner(:daisy, :ha_supervisor)

    snapshot = %DeviceSnapshot{
      device_id: :daisy,
      label: "DAISY",
      status: :unknown,
      updated_at: nil,
      offline_expected: false,
      metrics: %{},
      sources: %{}
    }

    restore_app_health(:daisy, :ha_supervisor, %{
      device_id: :daisy,
      source: :ha_supervisor,
      last_ok_at: nil,
      consecutive_failures: 0,
      backoff_ms: 0,
      last_error_at: nil,
      last_error: nil
    })

    SnapshotStore.put(snapshot)
    seed_device_hub(device, snapshot)

    on_exit(fn ->
      resume_source_runner(suspended_runner)
      clear_persistence_writer_queues()

      if previous_snapshot do
        SnapshotStore.put(previous_snapshot)
      end

      restore_device_hub(:daisy, previous_hub_state)
      restore_app_health(:daisy, :ha_supervisor, previous_health)
    end)
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

  defp set_bridge_token do
    previous = System.get_env("DAISY_SUPERVISOR_BRIDGE_TOKEN")
    System.put_env("DAISY_SUPERVISOR_BRIDGE_TOKEN", @bridge_token)

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("DAISY_SUPERVISOR_BRIDGE_TOKEN")
      else
        System.put_env("DAISY_SUPERVISOR_BRIDGE_TOKEN", previous)
      end
    end)
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

  defp serve_requests(listener, count, handler) do
    Task.async(fn ->
      try do
        Enum.each(1..count, fn _index ->
          {:ok, socket} = :gen_tcp.accept(listener)
          request = recv_http_request(socket)
          handler.(socket, request)
          :ok = :gen_tcp.close(socket)
        end)
      after
        :gen_tcp.close(listener)
      end
    end)
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

      {:error, reason} ->
        flunk("failed to receive HTTP request: #{inspect(reason)}")
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

  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(_status), do: "Error"

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
