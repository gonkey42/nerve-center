defmodule NerveCenter.Sources.Daisy.HASupervisorSourceTest do
  use NerveCenter.DataCase, async: false

  import ExUnit.CaptureLog

  alias NerveCenter.Sources.Daisy.HASupervisorSource
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
    context = %{source: source_config(1234)}

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

    assert {:ok, body} = @source.poll(%{source: source_config(port)})
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

    source =
      port
      |> source_config()
      |> Map.put(:supervisor_bridge_base_url, "http://127.0.0.1:#{port}/")

    assert {:ok, _body} = @source.poll(%{source: source})

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

    assert {:error, ^expected} = @source.poll(%{source: source_config(port)})

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
    %{source: source_config(0, addons), private: private}
  end

  defp source_config(port, addons \\ nil) do
    %{
      name: :ha_supervisor,
      module: NerveCenter.Sources.Daisy.HASupervisorSource,
      enabled: true,
      interval_ms: 60_000,
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

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(418), do: "I'm a teapot"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(_status), do: "Error"
end
