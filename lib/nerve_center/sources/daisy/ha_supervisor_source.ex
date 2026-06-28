defmodule NerveCenter.Sources.Daisy.HASupervisorSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: ["DAISY_SUPERVISOR_BRIDGE_TOKEN"]

  @impl true
  def normal_interval_ms, do: 60_000

  @impl true
  def stale_after_ms, do: 180_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       bridge_base_url: context.source.supervisor_bridge_base_url,
       protocol: "HTTP JSON bridge",
       watched_addons:
         Enum.map(
           context.source.supervisor_addons,
           &Map.take(&1, [:slug, :label, :required, :expected_states, :config_checks])
         )
     }}
  end

  @impl true
  def poll(context) do
    url = String.trim_trailing(context.source.supervisor_bridge_base_url, "/") <> "/health"

    case Support.request_json(url,
           headers: [
             {"authorization", "Bearer #{System.fetch_env!("DAISY_SUPERVISOR_BRIDGE_TOKEN")}"}
           ],
           receive_timeout: 5_000
         ) do
      {:ok, body} ->
        {:ok, body}

      {:error, {:auth, status, _body}} ->
        {:error, {:auth, status, :supervisor_bridge_unauthorized}}

      {:error, {:http, status, _body}} when status >= 500 ->
        {:error, {:http, status, :supervisor_bridge_unavailable}}

      {:error, {:http, status, _body}} ->
        {:error, {:http, status, :supervisor_bridge_unexpected_status}}

      {:error, {:request, reason}} ->
        {:error, {:request, reason}}
    end
  end

  @impl true
  def normalize(raw, context) do
    with {:ok, supervisor_raw} <- fetch_map(raw, :supervisor, :missing_supervisor),
         :ok <- validate_supervisor(supervisor_raw),
         {:ok, addons_raw} <- fetch_list(raw, :addons, :missing_addons),
         {:ok, observed_at} <- parse_observed_at(value(raw, :observed_at)),
         {:ok, observed_addons} <- observed_addons(addons_raw) do
      supervisor = normalize_supervisor(supervisor_raw)
      addons = normalize_addons(context.source.supervisor_addons, observed_addons)
      problems = supervisor.problems ++ Enum.flat_map(addons, & &1.problems)
      status = status_for(problems)
      required_unhealthy_count = unhealthy_count(addons, true)
      optional_unhealthy_count = unhealthy_count(addons, false)
      update_available_count = Enum.count(addons, &(&1.update_available == true))
      config_warning_count = Enum.sum(Enum.map(addons, &length(&1.config_warnings)))
      previous_fingerprints = previous_problem_fingerprints(context)
      problem_index = Map.new(problems, &{problem_fingerprint(&1), &1})
      current_fingerprints = MapSet.new(Map.keys(problem_index))

      events =
        transition_events(previous_fingerprints, current_fingerprints, problem_index, context)

      {:ok,
       %{
         status: status,
         observed_at: observed_at,
         metrics:
           aggregate_metrics(
             supervisor,
             required_unhealthy_count,
             optional_unhealthy_count,
             update_available_count,
             config_warning_count
           ),
         data: %{
           summary: %{
             status: status,
             problem_count: length(problems),
             required_unhealthy_count: required_unhealthy_count,
             optional_unhealthy_count: optional_unhealthy_count,
             update_available_count: update_available_count,
             message: summary_message(status, problems)
           },
           supervisor: supervisor,
           addons: addons
         },
         events: events,
         private: %{
           ha_supervisor_problem_fingerprints: current_fingerprints,
           ha_supervisor_addon_states: Map.new(addons, &{&1.slug, &1.state})
         }
       }}
    else
      {:error, reason} -> {:error, {:invalid_supervisor_bridge_payload, reason}}
    end
  end

  defp validate_supervisor(supervisor) do
    if is_boolean(value(supervisor, :healthy)) and is_boolean(value(supervisor, :supported)) do
      :ok
    else
      {:error, :missing_supervisor}
    end
  end

  defp fetch_map(map, key, reason) do
    case value(map, key) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp fetch_list(map, key, reason) do
    case value(map, key) do
      value when is_list(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp parse_observed_at(%DateTime{} = observed_at), do: {:ok, observed_at}

  defp parse_observed_at(observed_at) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _error -> {:error, :invalid_observed_at}
    end
  end

  defp parse_observed_at(_observed_at), do: {:error, :invalid_observed_at}

  defp observed_addons(addons) do
    Enum.reduce_while(addons, {:ok, %{}}, fn
      addon, {:ok, acc} when is_map(addon) ->
        case value(addon, :slug) do
          slug when is_binary(slug) -> {:cont, {:ok, Map.put(acc, slug, addon)}}
          _other -> {:halt, {:error, :invalid_addon_shape}}
        end

      _addon, _acc ->
        {:halt, {:error, :invalid_addon_shape}}
    end)
  end

  defp normalize_supervisor(supervisor) do
    normalized = %{
      version: sanitize(value(supervisor, :version)),
      version_latest: sanitize(value(supervisor, :version_latest)),
      update_available: value(supervisor, :update_available) == true,
      healthy: value(supervisor, :healthy),
      supported: value(supervisor, :supported),
      channel: sanitize(value(supervisor, :channel))
    }

    Map.put(normalized, :problems, supervisor_problems(normalized))
  end

  defp supervisor_problems(supervisor) do
    []
    |> maybe_problem(supervisor.healthy == false, %{
      scope: :supervisor,
      code: :supervisor_unhealthy,
      status: :error,
      value: false,
      message: "Home Assistant Supervisor reports unhealthy."
    })
    |> maybe_problem(supervisor.supported == false, %{
      scope: :supervisor,
      code: :supervisor_unsupported,
      status: :degraded,
      value: false,
      message: "Home Assistant Supervisor reports unsupported."
    })
  end

  defp normalize_addons(configured_addons, observed_addons) do
    Enum.map(
      configured_addons,
      &normalize_addon(&1, Map.get(observed_addons, config_value(&1, :slug)))
    )
  end

  defp normalize_addon(config, nil) do
    required = config_required?(config)

    problem = %{
      scope: :addon,
      addon: addon_identity(config),
      code:
        if(required, do: :bridge_missing_required_addon, else: :bridge_missing_optional_addon),
      status: if(required, do: :error, else: :degraded),
      value: "missing",
      message: "#{config_value(config, :label)} is missing from the supervisor bridge payload."
    }

    %{
      slug: config_value(config, :slug),
      label: config_value(config, :label),
      name: nil,
      required: required,
      expected_states: config_value(config, :expected_states, []),
      config_checks: config_value(config, :config_checks, []),
      state: nil,
      status: problem.status,
      observed?: false,
      drift?: true,
      available: false,
      boot: nil,
      startup: nil,
      protected: nil,
      network: %{},
      version: nil,
      version_latest: nil,
      update_available: false,
      config_summary: %{},
      config_warnings: [],
      problems: [problem]
    }
  end

  defp normalize_addon(config, observed) do
    required = config_required?(config)
    expected_states = config_value(config, :expected_states, [])
    state = sanitize(value(observed, :state))
    available = value(observed, :available, true)
    warnings = normalize_warnings(value(observed, :config_warnings, []))

    base = %{
      slug: config_value(config, :slug),
      label: config_value(config, :label),
      name: sanitize(value(observed, :name)),
      required: required,
      expected_states: expected_states,
      config_checks: config_value(config, :config_checks, []),
      state: state,
      observed?: true,
      drift?: false,
      available: available,
      boot: sanitize(value(observed, :boot)),
      startup: sanitize(value(observed, :startup)),
      protected: value(observed, :protected),
      network: sanitize(value(observed, :network, %{})),
      version: sanitize(value(observed, :version)),
      version_latest: sanitize(value(observed, :version_latest)),
      update_available: value(observed, :update_available) == true,
      config_summary: sanitize(value(observed, :config_summary, %{})),
      config_warnings: warnings
    }

    problems =
      []
      |> maybe_problem(
        addon_unhealthy?(state, available, expected_states),
        addon_unhealthy_problem(base)
      )
      |> Kernel.++(critical_config_warning_problems(base, warnings))

    status = status_for(problems)

    base
    |> Map.put(:status, status)
    |> Map.put(:problems, problems)
  end

  defp addon_unhealthy?(state, available, expected_states) do
    available == false or
      (is_list(expected_states) and expected_states != [] and state not in expected_states)
  end

  defp addon_unhealthy_problem(addon) do
    %{
      scope: :addon,
      addon: addon_identity(addon),
      code: if(addon.required, do: :required_addon_unhealthy, else: :optional_addon_unhealthy),
      status: if(addon.required, do: :error, else: :degraded),
      value: addon_unhealthy_value(addon),
      message: "#{addon.label} is #{addon_unhealthy_value(addon)}."
    }
  end

  defp addon_unhealthy_value(%{available: false}), do: "available:false"
  defp addon_unhealthy_value(%{state: state}) when is_binary(state), do: state
  defp addon_unhealthy_value(_addon), do: "missing_state"

  defp critical_config_warning_problems(addon, warnings) do
    warnings
    |> Enum.filter(&critical_warning?/1)
    |> Enum.map(fn warning ->
      %{
        scope: :addon,
        addon: addon_identity(addon),
        code:
          if(addon.required,
            do: :required_addon_critical_config_warning,
            else: :optional_addon_critical_config_warning
          ),
        status: if(addon.required, do: :error, else: :degraded),
        value: warning_code(warning),
        message: "#{addon.label} has a critical configuration warning."
      }
    end)
  end

  defp normalize_warnings(warnings) when is_list(warnings), do: Enum.map(warnings, &sanitize/1)
  defp normalize_warnings(_warnings), do: []

  defp critical_warning?(warning) do
    value(warning, :critical) == true or
      warning
      |> warning_level()
      |> to_string()
      |> String.downcase()
      |> Kernel.==("critical")
  end

  defp warning_level(warning) do
    value(warning, :severity) || value(warning, :level) || value(warning, :type)
  end

  defp warning_code(warning) do
    case value(warning, :code) do
      code when is_binary(code) -> code
      code when is_atom(code) -> Atom.to_string(code)
      _other -> "critical_config_warning"
    end
  end

  defp addon_identity(addon) do
    %{
      slug: config_value(addon, :slug),
      label: config_value(addon, :label)
    }
  end

  defp maybe_problem(problems, true, problem), do: problems ++ [problem]
  defp maybe_problem(problems, false, _problem), do: problems

  defp status_for(problems) do
    cond do
      Enum.any?(problems, &(&1.status == :error)) -> :error
      Enum.any?(problems, &(&1.status == :degraded)) -> :degraded
      true -> :ok
    end
  end

  defp unhealthy_count(addons, required?) do
    Enum.count(addons, fn addon ->
      addon.required == required? and addon.problems != []
    end)
  end

  defp aggregate_metrics(
         supervisor,
         required_unhealthy_count,
         optional_unhealthy_count,
         update_available_count,
         config_warning_count
       ) do
    [
      %{metric: :ha_supervisor_healthy_flag, value: flag(supervisor.healthy)},
      %{metric: :ha_supervisor_supported_flag, value: flag(supervisor.supported)},
      %{
        metric: :ha_supervisor_required_addons_unhealthy_count,
        value: required_unhealthy_count
      },
      %{
        metric: :ha_supervisor_optional_addons_unhealthy_count,
        value: optional_unhealthy_count
      },
      %{metric: :ha_supervisor_addons_update_available_count, value: update_available_count},
      %{metric: :ha_supervisor_addons_config_warning_count, value: config_warning_count}
    ]
  end

  defp flag(true), do: 1
  defp flag(_value), do: 0

  defp summary_message(:ok, []),
    do: "Home Assistant Supervisor and watched add-ons are healthy."

  defp summary_message(_status, problems),
    do: "#{length(problems)} Home Assistant Supervisor problem(s) detected."

  defp previous_problem_fingerprints(context) do
    context
    |> Map.get(:private, %{})
    |> Map.get(:ha_supervisor_problem_fingerprints, MapSet.new())
    |> to_mapset()
    |> sanitize_fingerprints()
  end

  defp to_mapset(%MapSet{} = value), do: value
  defp to_mapset(value) when is_list(value), do: MapSet.new(value)
  defp to_mapset(_value), do: MapSet.new()

  defp sanitize_fingerprints(fingerprints) do
    MapSet.new(fingerprints, &sanitize/1)
  end

  defp transition_events(previous_fingerprints, current_fingerprints, problem_index, context) do
    new_events =
      current_fingerprints
      |> MapSet.difference(previous_fingerprints)
      |> Enum.sort()
      |> Enum.map(&new_problem_event(Map.fetch!(problem_index, &1)))

    recovery_events =
      previous_fingerprints
      |> MapSet.difference(current_fingerprints)
      |> Enum.sort()
      |> Enum.map(&recovery_event(&1, context))

    new_events ++ recovery_events
  end

  defp new_problem_event(%{scope: :supervisor} = problem) do
    %{
      event_type: :ha_supervisor_unhealthy,
      code: problem.code,
      fingerprint: problem_fingerprint(problem),
      message: problem.message
    }
  end

  defp new_problem_event(%{addon: addon} = problem) do
    %{
      event_type: :ha_supervisor_addon_problem,
      code: problem.code,
      fingerprint: problem_fingerprint(problem),
      message: "#{addon.label} problem: #{problem.code}."
    }
  end

  defp recovery_event("supervisor:" <> _rest = fingerprint, _context) do
    %{
      event_type: :ha_supervisor_recovered,
      code: fingerprint_code(fingerprint),
      fingerprint: sanitize(fingerprint),
      message: "Home Assistant Supervisor problem recovered."
    }
  end

  defp recovery_event(fingerprint, context) do
    slug = fingerprint |> String.split(":", parts: 2) |> List.first()
    label = addon_label(context.source.supervisor_addons, slug)

    %{
      event_type: :ha_supervisor_addon_recovered,
      code: fingerprint_code(fingerprint),
      fingerprint: sanitize(fingerprint),
      message: "#{label} problem recovered."
    }
  end

  defp fingerprint_code(fingerprint) do
    fingerprint
    |> String.split(":", parts: 3)
    |> case do
      [_scope_or_slug, code, _value] -> existing_code_atom(code)
      _parts -> :unknown
    end
  end

  defp existing_code_atom(code) do
    String.to_existing_atom(code)
  rescue
    ArgumentError -> :unknown
  end

  defp addon_label(configured_addons, slug) do
    configured_addons
    |> Enum.find(&(config_value(&1, :slug) == slug))
    |> case do
      nil -> slug
      config -> config_value(config, :label, slug)
    end
  end

  defp problem_fingerprint(%{scope: :supervisor} = problem),
    do: "supervisor:#{problem.code}:#{problem.value}"

  defp problem_fingerprint(%{addon: addon} = problem),
    do: "#{addon.slug}:#{problem.code}:#{problem.value}"

  defp config_required?(config), do: config_value(config, :required, false) == true

  defp config_value(map, key, default \\ nil), do: value(map, key, default)

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    string_key = if is_atom(key), do: Atom.to_string(key), else: key

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      Map.has_key?(map, string_key) ->
        Map.get(map, string_key)

      true ->
        value_for_existing_atom_key(map, key, default)
    end
  end

  defp value(_map, _key, default), do: default

  defp value_for_existing_atom_key(map, key, default) do
    case existing_atom_key(key) do
      {:ok, atom_key} ->
        if Map.has_key?(map, atom_key), do: Map.get(map, atom_key), else: default

      :error ->
        default
    end
  end

  defp existing_atom_key(key) when is_atom(key), do: {:ok, key}

  defp existing_atom_key(key) when is_binary(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom_key(_key), do: :error

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize(nested_value)}
      end
    end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_binary(value) do
    value
    |> redact_regex(~r/Traceback/i, "[REDACTED]")
    |> redact_regex(~r/Authorization:\s*Bearer\s+[A-Za-z0-9_-]{20,}/i, "[REDACTED]")
    |> redact_regex(~r/Bearer\s+[A-Za-z0-9_-]{20,}/, "Bearer [REDACTED]")
    |> redact_regex(~r/Authorization/i, "[REDACTED]")
    |> redact_regex(~r/[A-Za-z0-9_-]*token[A-Za-z0-9_-]*/i, "[REDACTED]")
    |> redact_regex(~r/[A-Za-z0-9_-]*password[A-Za-z0-9_-]*/i, "[REDACTED]")
  end

  defp sanitize(value), do: value

  defp redact_regex(value, regex, replacement), do: Regex.replace(regex, value, replacement)

  defp sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    normalized in ["authorization", "password", "token", "access_token", "bridge_token"] or
      String.ends_with?(normalized, "_token")
  end
end
