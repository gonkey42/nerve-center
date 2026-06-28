defmodule NerveCenter.Sources.Daisy.HASupervisorSourceTest do
  use NerveCenter.DataCase, async: false

  import ExUnit.CaptureLog

  import NerveCenter.TestSupport.DaisySupervisorBridgeHelpers,
    only: [listen_socket: 0, send_response: 2, serve_requests: 3]

  import NerveCenter.TestSupport.PersistenceWriterHelpers,
    only: [
      assert_persistence_count_stable: 3,
      clear_persistence_writer_queues: 0
    ]

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Persistence.DeviceEvent
  alias NerveCenter.Repo
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.PollingSourceRunner
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Sources.Daisy.HASupervisorSource
  alias NerveCenter.Topology

  import HASupervisorSource, only: []

  @source HASupervisorSource

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

  setup do
    previous = System.get_env("DAISY_SUPERVISOR_BRIDGE_TOKEN")
    System.put_env("DAISY_SUPERVISOR_BRIDGE_TOKEN", @bridge_token)

    on_exit(fn ->
      if is_nil(previous) do
        System.delete_env("DAISY_SUPERVISOR_BRIDGE_TOKEN")
      else
        System.put_env("DAISY_SUPERVISOR_BRIDGE_TOKEN", previous)
      end
    end)

    :ok
  end

  @tag :poll
  test "required_env requires only the bridge token" do
    assert @source.required_env() == ["DAISY_SUPERVISOR_BRIDGE_TOKEN"]
  end

  @tag :poll
  test "probe records bridge base url watched addons and protocol" do
    context = runtime_context(1234)

    assert {:ok, probe} = @source.probe(context)

    assert probe.bridge_base_url == "http://127.0.0.1:1234"
    assert probe.protocol == "HTTP JSON bridge"

    assert probe.watched_addons == [
             %{
               slug: "a0d7b954_nut",
               label: "Network UPS Tools",
               required: true,
               expected_states: ["started"],
               config_checks: [:nut_addon]
             }
           ]

    refute inspect(probe) =~ @bridge_token
  end

  @tag :poll
  test "probe reads bridge config from device when source only has runner metadata" do
    context = %{device: device_config(1234), source: source_metadata_config(), private: %{}}

    assert {:ok, probe} = @source.probe(context)

    assert probe.bridge_base_url == "http://127.0.0.1:1234"

    assert probe.watched_addons == [
             %{
               slug: "a0d7b954_nut",
               label: "Network UPS Tools",
               required: true,
               expected_states: ["started"],
               config_checks: [:nut_addon]
             }
           ]
  end

  @tag :poll
  test "probe falls back to explicit source-level bridge config" do
    context = %{source: source_config(1234), private: %{}}

    assert {:ok, probe} = @source.probe(context)

    assert probe.bridge_base_url == "http://127.0.0.1:1234"

    assert probe.watched_addons == [
             %{
               slug: "a0d7b954_nut",
               label: "Network UPS Tools",
               required: true,
               expected_states: ["started"],
               config_checks: [:nut_addon]
             }
           ]
  end

  @tag :poll
  test "poll sends authorization bearer token" do
    {listener, port} = listen_socket()

    server =
      serve_requests(listener, 1, fn socket, request ->
        assert String.contains?(
                 String.downcase(request),
                 "authorization: bearer #{@bridge_token}"
               )

        assert String.contains?(request, "GET /health HTTP/1.1")
        send_response(socket, {200, bridge_payload()})
      end)

    assert {:ok, body} = @source.poll(runtime_context(port))
    assert body["supervisor"]["version"] == "2026.06.2"

    Task.await(server)
  end

  @tag :poll
  test "poll sanitizes bridge 401 body" do
    assert_sanitized_poll_error(401, {:auth, 401, :supervisor_bridge_unauthorized})
  end

  @tag :poll
  test "poll sanitizes bridge 403 body" do
    assert_sanitized_poll_error(403, {:auth, 403, :supervisor_bridge_unauthorized})
  end

  @tag :poll
  test "poll sanitizes bridge 5xx body" do
    assert_sanitized_poll_error(503, {:http, 503, :supervisor_bridge_unavailable})
  end

  @tag :poll
  test "poll sanitizes unexpected non-auth non-5xx status body" do
    assert_sanitized_poll_error(418, {:http, 418, :supervisor_bridge_unexpected_status})
  end

  @tag :poll
  test "poll joins trailing slash bridge base url to exactly health path" do
    {listener, port} = listen_socket()

    server =
      serve_requests(listener, 1, fn socket, request ->
        assert String.contains?(request, "GET /health HTTP/1.1")
        refute String.contains?(request, "GET //health HTTP/1.1")
        send_response(socket, {200, bridge_payload()})
      end)

    device =
      port
      |> device_config()
      |> Map.put(:supervisor_bridge_base_url, "http://127.0.0.1:#{port}/")

    assert {:ok, _body} =
             @source.poll(%{device: device, source: source_metadata_config(), private: %{}})

    Task.await(server)
  end

  test "malformed payload reports structural reason without raw payload" do
    payload =
      bridge_payload(%{
        "observed_at" => @forbidden_password,
        "supervisor" => %{"password" => @forbidden_password}
      })

    log =
      capture_log(fn ->
        assert {:error, {:invalid_supervisor_bridge_payload, reason}} =
                 @source.normalize(payload, context())

        assert reason in [
                 :missing_supervisor,
                 :missing_addons,
                 :invalid_observed_at,
                 :invalid_addon_shape
               ]

        refute inspect(reason) =~ @forbidden_password
      end)

    refute log =~ @forbidden_password
  end

  test "normalize handles string-key decoded bridge json" do
    assert {:ok, payload} = @source.normalize(bridge_payload(), context())

    assert payload.observed_at == ~U[2026-06-28 13:03:42Z]
    assert payload.status == :ok
    assert payload.data.supervisor.version == "2026.06.2"
    assert addon(payload, "a0d7b954_nut").name == "Network UPS Tools"
    assert payload.private.ha_supervisor_addon_states == %{"a0d7b954_nut" => "started"}
  end

  test "normalize maps healthy supervisor and addon to ok" do
    payload = normalize!()

    assert payload.status == :ok
    assert payload.data.summary.status == :ok
    assert payload.data.summary.problem_count == 0
    assert payload.data.summary.required_unhealthy_count == 0
    assert payload.data.summary.optional_unhealthy_count == 0

    assert payload.data.summary.message ==
             "Home Assistant Supervisor and watched add-ons are healthy."

    assert payload.data.supervisor.problems == []
    assert addon(payload, "a0d7b954_nut").status == :ok
    assert addon(payload, "a0d7b954_nut").problems == []
  end

  test "normalize maps supervisor unhealthy to error" do
    payload =
      normalize!(
        bridge_payload(%{
          "supervisor" => Map.put(bridge_payload()["supervisor"], "healthy", false)
        })
      )

    assert payload.status == :error
    assert payload.data.summary.problem_count == 1

    assert [%{code: :supervisor_unhealthy, status: :error, value: false}] =
             payload.data.supervisor.problems
  end

  test "normalize maps supervisor unsupported to degraded" do
    payload =
      normalize!(
        bridge_payload(%{
          "supervisor" => Map.put(bridge_payload()["supervisor"], "supported", false)
        })
      )

    assert payload.status == :degraded

    assert [%{code: :supervisor_unsupported, status: :degraded, value: false}] =
             payload.data.supervisor.problems
  end

  test "malformed payload rejects missing or non-boolean supervisor health fields" do
    missing_healthy =
      bridge_payload(%{
        "supervisor" => Map.delete(bridge_payload()["supervisor"], "healthy")
      })

    non_boolean_supported =
      bridge_payload(%{
        "supervisor" => Map.put(bridge_payload()["supervisor"], "supported", "unknown")
      })

    assert {:error, {:invalid_supervisor_bridge_payload, :missing_supervisor}} =
             @source.normalize(missing_healthy, context())

    assert {:error, {:invalid_supervisor_bridge_payload, :missing_supervisor}} =
             @source.normalize(non_boolean_supported, context())
  end

  test "normalize maps required addon error to error" do
    payload = normalize!(bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]}))

    assert payload.status == :error
    assert payload.data.summary.required_unhealthy_count == 1
    assert addon(payload, "a0d7b954_nut").status == :error
    assert has_problem?(payload, "a0d7b954_nut", :required_addon_unhealthy)
  end

  test "normalize maps required critical config warning to error" do
    payload =
      normalize!(
        bridge_payload(%{
          "addons" => [
            addon_payload(%{
              "config_warnings" => [
                %{"severity" => "critical", "code" => "nut_missing_primary_user"}
              ]
            })
          ]
        })
      )

    assert payload.status == :error
    assert payload.data.summary.required_unhealthy_count == 1
    assert has_problem?(payload, "a0d7b954_nut", :required_addon_critical_config_warning)
  end

  test "normalize maps optional critical config warning to degraded" do
    optional = [addon_config(%{required: false})]

    payload =
      normalize!(
        bridge_payload(%{
          "addons" => [
            addon_payload(%{
              "config_warnings" => [
                %{"severity" => "critical", "code" => "nut_missing_primary_user"}
              ]
            })
          ]
        }),
        optional
      )

    assert payload.status == :degraded
    assert payload.data.summary.optional_unhealthy_count == 1
    assert has_problem?(payload, "a0d7b954_nut", :optional_addon_critical_config_warning)
  end

  test "normalize maps missing required addon to error drift" do
    payload = normalize!(bridge_payload(%{"addons" => []}))

    assert payload.status == :error
    assert payload.data.summary.required_unhealthy_count == 1
    assert addon(payload, "a0d7b954_nut").drift? == true
    assert has_problem?(payload, "a0d7b954_nut", :bridge_missing_required_addon)
  end

  test "normalize maps missing optional addon to degraded drift" do
    optional = [addon_config(%{required: false})]
    payload = normalize!(bridge_payload(%{"addons" => []}), optional)

    assert payload.status == :degraded
    assert payload.data.summary.optional_unhealthy_count == 1
    assert addon(payload, "a0d7b954_nut").drift? == true
    assert has_problem?(payload, "a0d7b954_nut", :bridge_missing_optional_addon)
  end

  test "normalize maps optional unhealthy addon to degraded" do
    optional = [addon_config(%{required: false})]

    payload =
      normalize!(
        bridge_payload(%{"addons" => [addon_payload(%{"state" => "stopped"})]}),
        optional
      )

    assert payload.status == :degraded
    assert payload.data.summary.optional_unhealthy_count == 1
    assert addon(payload, "a0d7b954_nut").status == :degraded
    assert has_problem?(payload, "a0d7b954_nut", :optional_addon_unhealthy)
  end

  test "normalize treats update_available as data only by default" do
    payload =
      normalize!(
        bridge_payload(%{
          "addons" => [addon_payload(%{"update_available" => true, "version_latest" => "0.19.0"})]
        })
      )

    assert payload.status == :ok
    assert payload.data.summary.update_available_count == 1
    assert addon(payload, "a0d7b954_nut").update_available == true
    assert addon(payload, "a0d7b954_nut").version_latest == "0.19.0"
    assert addon(payload, "a0d7b954_nut").problems == []
  end

  test "normalize emits aggregate metrics" do
    payload =
      normalize!(
        bridge_payload(%{
          "supervisor" =>
            bridge_payload()["supervisor"]
            |> Map.put("healthy", false)
            |> Map.put("supported", false),
          "addons" => [
            addon_payload(%{
              "update_available" => true,
              "config_warnings" => [
                %{"severity" => "warning", "code" => "nut_optional_note"},
                %{"severity" => "info", "code" => "nut_info_note"}
              ]
            })
          ]
        })
      )

    assert metrics(payload) == %{
             ha_supervisor_healthy_flag: 0,
             ha_supervisor_supported_flag: 0,
             ha_supervisor_required_addons_unhealthy_count: 0,
             ha_supervisor_optional_addons_unhealthy_count: 0,
             ha_supervisor_addons_update_available_count: 1,
             ha_supervisor_addons_config_warning_count: 2
           }
  end

  test "normalize redacts raw passwords from output" do
    payload =
      normalize!(
        bridge_payload(%{
          "addons" => [
            addon_payload(%{
              "config_summary" => %{
                "mode" => "netserver",
                "password" => @forbidden_password,
                "token" => @forbidden_bridge_token,
                "supervisor_token" => @forbidden_supervisor_token,
                "Authorization" => "Bearer #{@forbidden_bridge_token}",
                "password_set" => true
              },
              "config_warnings" => [
                %{
                  "severity" => "warning",
                  "code" => "redacted_secret_seen",
                  "password" => @forbidden_password
                }
              ]
            })
          ]
        })
      )

    rendered = inspect(payload)

    refute rendered =~ @forbidden_password
    refute rendered =~ @forbidden_bridge_token
    refute rendered =~ @forbidden_supervisor_token
    refute rendered =~ "Authorization: Bearer #{@forbidden_bridge_token}"
    assert addon(payload, "a0d7b954_nut").config_summary["password_set"] == true
  end

  test "normalize sanitizes warning strings before data problems fingerprints events and logs" do
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, payload} =
                 @source.normalize(
                   bridge_payload(%{
                     "addons" => [
                       addon_payload(%{
                         "config_warnings" => [
                           %{
                             "severity" => "critical",
                             "code" =>
                               "nut_leaked_#{@forbidden_password}_#{@forbidden_bridge_token}",
                             "message" =>
                               "Authorization: Bearer #{@forbidden_bridge_token} #{@forbidden_supervisor_token}",
                             "trace" => "Traceback fake failure #{@forbidden_password}"
                           },
                           %{
                             "severity" => "critical",
                             "code" => "nut_username_blank",
                             "message" => "NUT username is blank."
                           }
                         ]
                       })
                     ]
                   }),
                   context()
                 )

        send(parent, {:payload, payload})
      end)

    assert_receive {:payload, payload}
    warning_rendered = inspect(addon(payload, "a0d7b954_nut").config_warnings)
    event_rendered = inspect(payload.events)
    private_rendered = inspect(payload.private)
    rendered = inspect(payload)

    for output <- [warning_rendered, event_rendered, private_rendered, rendered, log],
        forbidden <- forbidden_fragments() do
      refute output =~ forbidden
    end

    assert Enum.any?(addon(payload, "a0d7b954_nut").config_warnings, fn warning ->
             warning["code"] == "nut_username_blank"
           end)

    assert Enum.any?(addon(payload, "a0d7b954_nut").problems, fn problem ->
             problem.value == "nut_username_blank"
           end)
  end

  test "normalize sanitizes bridge scalar strings before data problems fingerprints events and logs" do
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, payload} =
                 @source.normalize(
                   bridge_payload(%{
                     "supervisor" =>
                       bridge_payload()["supervisor"]
                       |> Map.put("version", "2026.06.2 #{@forbidden_bridge_token}")
                       |> Map.put("version_latest", "Traceback #{@forbidden_supervisor_token}")
                       |> Map.put("channel", "stable #{@forbidden_password}"),
                     "addons" => [
                       addon_payload(%{
                         "name" => "Network UPS Tools #{@forbidden_supervisor_token}",
                         "state" => "Traceback Bearer #{@forbidden_bridge_token}",
                         "available" => "true #{@forbidden_bridge_token}",
                         "boot" => "auto #{@forbidden_password}",
                         "startup" => "Authorization: Bearer #{@forbidden_bridge_token}",
                         "protected" => "false #{@forbidden_supervisor_token}",
                         "version" => "0.18.0 #{@forbidden_bridge_token}",
                         "version_latest" => "Traceback #{@forbidden_supervisor_token}"
                       })
                     ]
                   }),
                   context()
                 )

        send(parent, {:payload, payload})
      end)

    assert_receive {:payload, payload}

    assert payload.status == :error
    assert addon(payload, "a0d7b954_nut").status == :error
    assert has_problem?(payload, "a0d7b954_nut", :required_addon_unhealthy)
    assert is_nil(addon(payload, "a0d7b954_nut").available)
    assert is_nil(addon(payload, "a0d7b954_nut").protected)

    assert payload.private.ha_supervisor_addon_states["a0d7b954_nut"] !=
             "Traceback Bearer #{@forbidden_bridge_token}"

    assert [%{fingerprint: fingerprint}] = payload.events
    assert fingerprint =~ "a0d7b954_nut:required_addon_unhealthy:"

    for output <- [
          inspect(payload.data.supervisor),
          inspect(addon(payload, "a0d7b954_nut")),
          inspect(payload.events),
          inspect(payload.private),
          inspect(payload),
          log
        ],
        forbidden <- forbidden_fragments() do
      refute output =~ forbidden
    end
  end

  test "normalize emits events only on problem fingerprint changes" do
    first = normalize!(bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]}))

    assert first.events == [
             %{
               event_type: :ha_supervisor_addon_problem,
               code: :required_addon_unhealthy,
               fingerprint: "a0d7b954_nut:required_addon_unhealthy:error",
               message: "Network UPS Tools problem: required_addon_unhealthy."
             }
           ]

    second =
      normalize!(
        bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]}),
        nil,
        first.private
      )

    assert second.events == []

    assert second.private.ha_supervisor_problem_fingerprints ==
             first.private.ha_supervisor_problem_fingerprints
  end

  test "normalize emits recovery events when problem fingerprints disappear" do
    problem = normalize!(bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]}))
    recovered = normalize!(bridge_payload(), nil, problem.private)

    assert recovered.events == [
             %{
               event_type: :ha_supervisor_addon_recovered,
               code: :required_addon_unhealthy,
               fingerprint: "a0d7b954_nut:required_addon_unhealthy:error",
               message: "Network UPS Tools problem recovered."
             }
           ]

    assert recovered.status == :ok
    assert recovered.private.ha_supervisor_problem_fingerprints == MapSet.new()
  end

  test "normalize sanitizes legacy secret-bearing recovery fingerprints" do
    legacy_fingerprint =
      "a0d7b954_nut:required_addon_critical_config_warning:nut_leaked_#{@forbidden_password}_#{@forbidden_bridge_token}_Authorization: Bearer #{@forbidden_bridge_token}_Traceback_#{@forbidden_supervisor_token}"

    private = %{
      ha_supervisor_problem_fingerprints: MapSet.new([legacy_fingerprint])
    }

    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, payload} = @source.normalize(bridge_payload(), context(nil, private))
        send(parent, {:payload, payload})
      end)

    assert_receive {:payload, payload}

    assert [
             %{
               event_type: :ha_supervisor_addon_recovered,
               code: :required_addon_critical_config_warning,
               fingerprint: fingerprint,
               message: "Network UPS Tools problem recovered."
             }
           ] = payload.events

    assert fingerprint =~ "a0d7b954_nut:required_addon_critical_config_warning:"
    assert fingerprint != legacy_fingerprint

    for output <- [fingerprint, inspect(payload.events), inspect(payload), log],
        forbidden <- forbidden_fragments() do
      refute output =~ forbidden
    end
  end

  test "normalize dedupes active legacy unsanitized fingerprints against current sanitized problems" do
    legacy_fingerprint =
      "a0d7b954_nut:required_addon_unhealthy:Traceback Bearer #{@forbidden_bridge_token}"

    private = %{
      ha_supervisor_problem_fingerprints: MapSet.new([legacy_fingerprint])
    }

    payload =
      normalize!(
        bridge_payload(%{
          "addons" => [
            addon_payload(%{"state" => "Traceback Bearer #{@forbidden_bridge_token}"})
          ]
        }),
        nil,
        private
      )

    assert payload.status == :error
    assert payload.events == []
    assert [fingerprint] = MapSet.to_list(payload.private.ha_supervisor_problem_fingerprints)
    assert fingerprint != legacy_fingerprint
    assert fingerprint =~ "a0d7b954_nut:required_addon_unhealthy:"

    for output <- [fingerprint, inspect(payload.private), inspect(payload)],
        forbidden <- forbidden_fragments() do
      refute output =~ forbidden
    end
  end

  test "normalize emits supervisor unhealthy and recovered events when supervisor problems change" do
    unhealthy =
      normalize!(
        bridge_payload(%{
          "supervisor" => Map.put(bridge_payload()["supervisor"], "healthy", false)
        })
      )

    assert unhealthy.events == [
             %{
               event_type: :ha_supervisor_unhealthy,
               code: :supervisor_unhealthy,
               fingerprint: "supervisor:supervisor_unhealthy:false",
               message: "Home Assistant Supervisor reports unhealthy."
             }
           ]

    unsupported =
      normalize!(
        bridge_payload(%{
          "supervisor" => Map.put(bridge_payload()["supervisor"], "supported", false)
        }),
        nil,
        unhealthy.private
      )

    assert unsupported.events == [
             %{
               event_type: :ha_supervisor_unhealthy,
               code: :supervisor_unsupported,
               fingerprint: "supervisor:supervisor_unsupported:false",
               message: "Home Assistant Supervisor reports unsupported."
             },
             %{
               event_type: :ha_supervisor_recovered,
               code: :supervisor_unhealthy,
               fingerprint: "supervisor:supervisor_unhealthy:false",
               message: "Home Assistant Supervisor problem recovered."
             }
           ]

    recovered = normalize!(bridge_payload(), nil, unsupported.private)

    assert recovered.events == [
             %{
               event_type: :ha_supervisor_recovered,
               code: :supervisor_unsupported,
               fingerprint: "supervisor:supervisor_unsupported:false",
               message: "Home Assistant Supervisor problem recovered."
             }
           ]

    assert recovered.status == :ok
  end

  test "runner persists a problem event once for a stable fingerprint" do
    clear_persistence_writer_queues()
    delete_ha_supervisor_events()

    {listener, port} = listen_socket()
    payload = bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]})

    server =
      serve_requests(listener, 2, fn socket, _request ->
        send_response(socket, {200, payload})
      end)

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(:daisy, :ha_supervisor))

    runner = start_ha_supervisor_runner(port)

    assert_receive %SourceSnapshotUpdated{source_snapshot: first_snapshot}, 1_000
    assert first_snapshot.status == :error

    send(runner, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: second_snapshot}, 1_000
    assert second_snapshot.status == :error

    assert_persistence_count_stable(
      "ha_supervisor_addon_problem events",
      fn -> count_ha_supervisor_events("ha_supervisor_addon_problem") end,
      1
    )

    Task.await(server)
  end

  test "runner persists recovery event when a fingerprint disappears" do
    clear_persistence_writer_queues()
    delete_ha_supervisor_events()

    {listener, port} = listen_socket()

    server =
      serve_requests(listener, 2, fn
        socket, request ->
          response =
            if String.contains?(request, "GET /health HTTP/1.1") do
              receive do
                {:bridge_response, payload} -> payload
              after
                1_000 -> flunk("bridge response was not supplied")
              end
            end

          send_response(socket, {200, response})
      end)

    send(server.pid, {
      :bridge_response,
      bridge_payload(%{"addons" => [addon_payload(%{"state" => "error"})]})
    })

    Phoenix.PubSub.subscribe(NerveCenter.PubSub, Topology.source_topic(:daisy, :ha_supervisor))

    runner = start_ha_supervisor_runner(port)

    assert_receive %SourceSnapshotUpdated{source_snapshot: problem_snapshot}, 1_000
    assert problem_snapshot.status == :error

    send(server.pid, {:bridge_response, bridge_payload()})
    send(runner, :poll)

    assert_receive %SourceSnapshotUpdated{source_snapshot: recovered_snapshot}, 1_000
    assert recovered_snapshot.status == :ok

    wait_until(fn ->
      count_ha_supervisor_events("ha_supervisor_addon_problem") == 1 and
        count_ha_supervisor_events("ha_supervisor_addon_recovered") == 1
    end)

    events =
      DeviceEvent
      |> where([event], event.device_id == "daisy" and event.source == "ha_supervisor")
      |> Repo.all()

    assert Enum.any?(events, &(&1.event_type == "ha_supervisor_addon_problem"))
    assert Enum.any?(events, &(&1.event_type == "ha_supervisor_addon_recovered"))

    Task.await(server)
  end

  defp assert_sanitized_poll_error(status, expected) do
    {listener, port} = listen_socket()

    server =
      serve_requests(listener, 1, fn socket, request ->
        assert String.contains?(
                 String.downcase(request),
                 "authorization: bearer #{@bridge_token}"
               )

        send_response(socket, {status, @forbidden_body})
      end)

    assert {:error, ^expected} = @source.poll(runtime_context(port))

    rendered = inspect(expected)
    refute rendered =~ @forbidden_password
    refute rendered =~ @forbidden_bridge_token
    refute rendered =~ @forbidden_supervisor_token
    refute rendered =~ "Authorization: Bearer #{@forbidden_bridge_token}"

    Task.await(server)
  end

  defp normalize!(payload \\ bridge_payload(), addons \\ nil, private \\ %{}) do
    assert {:ok, normalized} = @source.normalize(payload, context(addons, private))
    normalized
  end

  defp context(addons \\ nil, private \\ %{}) do
    runtime_context(0, addons, private)
  end

  defp runtime_context(port, addons \\ nil, private \\ %{}) do
    %{device: device_config(port, addons), source: source_metadata_config(), private: private}
  end

  defp device_config(port, addons \\ nil) do
    %{
      id: :daisy,
      supervisor_bridge_base_url: "http://127.0.0.1:#{port}",
      supervisor_addons:
        addons ||
          [
            %{
              slug: "a0d7b954_nut",
              label: "Network UPS Tools",
              required: true,
              expected_states: ["started"],
              config_checks: [:nut_addon]
            }
          ]
    }
  end

  defp source_metadata_config do
    %{
      name: :ha_supervisor,
      module: NerveCenter.Sources.Daisy.HASupervisorSource,
      enabled: true,
      interval_ms: 60_000
    }
  end

  defp source_config(port) do
    Map.merge(source_metadata_config(), %{
      supervisor_bridge_base_url: "http://127.0.0.1:#{port}",
      supervisor_addons: [
        %{
          slug: "a0d7b954_nut",
          label: "Network UPS Tools",
          required: true,
          expected_states: ["started"],
          config_checks: [:nut_addon]
        }
      ]
    })
  end

  defp addon_config(overrides) do
    Map.merge(
      %{
        slug: "a0d7b954_nut",
        label: "Network UPS Tools",
        required: true,
        expected_states: ["started"],
        config_checks: [:nut_addon]
      },
      overrides
    )
  end

  defp bridge_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "observed_at" => "2026-06-28T13:03:42Z",
        "supervisor" => %{
          "version" => "2026.06.2",
          "version_latest" => "2026.06.2",
          "update_available" => false,
          "healthy" => true,
          "supported" => true,
          "channel" => "stable"
        },
        "addons" => [
          addon_payload()
        ]
      },
      overrides
    )
  end

  defp addon_payload(overrides \\ %{}) do
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

  defp metrics(payload), do: Map.new(payload.metrics, &{&1.metric, &1.value})

  defp addon(payload, slug) do
    Enum.find(payload.data.addons, &(&1.slug == slug))
  end

  defp has_problem?(payload, slug, code) do
    payload
    |> addon(slug)
    |> Map.fetch!(:problems)
    |> Enum.any?(&(&1.code == code))
  end

  defp forbidden_fragments do
    [
      @forbidden_password,
      @forbidden_bridge_token,
      @forbidden_supervisor_token,
      "Authorization",
      "Traceback"
    ]
  end

  defp start_ha_supervisor_runner(port) do
    device =
      :daisy
      |> Topology.get_device!()
      |> Map.put(:supervisor_bridge_base_url, "http://127.0.0.1:#{port}")

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

    seed_app_health(:daisy, :ha_supervisor)
    SnapshotStore.put(snapshot)
    seed_device_hub(device, snapshot)

    on_exit(fn ->
      resume_source_runner(suspended_runner)
      clear_persistence_writer_queues()
      delete_ha_supervisor_events()

      if previous_snapshot do
        SnapshotStore.put(previous_snapshot)
      end

      restore_device_hub(:daisy, previous_hub_state)
      restore_app_health(:daisy, :ha_supervisor, previous_health)
    end)

    start_supervised!(
      {PollingSourceRunner, module: @source, device: device, source: source_metadata_config()}
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
    restore_app_health(device_id, source_name, %{
      device_id: device_id,
      source: source_name,
      last_ok_at: nil,
      consecutive_failures: 0,
      backoff_ms: 0,
      last_error_at: nil,
      last_error: nil
    })
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

  defp delete_ha_supervisor_events do
    Repo.delete_all(
      from event in DeviceEvent,
        where: event.device_id == "daisy" and event.source == "ha_supervisor"
    )
  end

  defp count_ha_supervisor_events(event_type) do
    DeviceEvent
    |> where(
      [event],
      event.device_id == "daisy" and event.source == "ha_supervisor" and
        event.event_type == ^event_type
    )
    |> Repo.aggregate(:count, :id)
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
