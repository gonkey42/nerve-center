defmodule NerveCenter.Runtime.ManualControl do
  @moduledoc false

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.SemanticStatus
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Topology

  @safe_request_reasons [
    :closed,
    :connrefused,
    :econnrefused,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :nxdomain,
    :timeout
  ]
  @safe_callback_error_atoms [:offline, :timeout, :unavailable]
  @safe_catch_kinds [:error, :exit, :throw]

  def refresh_source(device_id, source_name) do
    device = Topology.get_device!(device_id)
    source = Topology.get_source!(device.id, source_name)
    module = source.module
    previous = current_source_snapshot(device.id, source.name)
    context = context(device, source, previous)

    with {:ok, probe_data} <- module.probe(context),
         probed_context <- %{context | probe_data: %{ok: true, data: probe_data}},
         {:ok, raw} <- module.poll(probed_context),
         {:ok, payload} <- module.normalize(raw, probed_context),
         {:ok, semantic_status} <- SemanticStatus.normalize(payload) do
      {:ok,
       publish_success(device, source, payload, semantic_status, %{ok: true, data: probe_data})}
    else
      {:error, reason} -> {:error, sanitize_refresh_error(reason)}
      other -> {:error, sanitize_refresh_error({:invalid_callback_return, other})}
    end
  rescue
    error -> {:error, sanitize_refresh_error({:exception, error})}
  catch
    kind, reason -> {:error, sanitize_refresh_error({:caught, kind, reason})}
  end

  defp publish_success(device, source, payload, semantic_status, probe_data) do
    observed_at = observed_at(payload)
    normalized_metrics = Catalog.normalize(Map.get(payload, :metrics, []) || [])
    metric_map = Map.new(normalized_metrics, &{&1.metric_id, &1.metric_value})
    data = data(source, payload)

    PersistenceWriter.enqueue_probe(%{
      device_id: Atom.to_string(device.id),
      source: Atom.to_string(source.name),
      probe_data: probe_data,
      probed_at: observed_at
    })

    PersistenceWriter.enqueue_samples(
      Enum.map(normalized_metrics, fn metric ->
        %{
          device_id: Atom.to_string(device.id),
          source: Atom.to_string(source.name),
          metric_name: metric.metric_name,
          metric_value: metric.metric_value / 1,
          recorded_at: observed_at
        }
      end)
    )

    source_snapshot = %SourceSnapshot{
      device_id: device.id,
      source: source.name,
      status: semantic_status,
      observed_at: observed_at,
      last_ok_at: observed_at,
      last_error_at: nil,
      last_error: nil,
      probe_data: probe_data,
      consecutive_failures: 0,
      backoff_ms: 0,
      ever_ok?: true,
      metrics: metric_map,
      data: data
    }

    AppHealth.record_source_success(device.id, source.name, observed_at)
    publish_source_snapshot(device, source, source_snapshot, observed_at)

    source_snapshot
  end

  defp context(device, source, previous) do
    %{
      device: device,
      source: source,
      interval_ms: Map.get(source, :interval_ms, source.module.normal_interval_ms()),
      private: %{},
      probe_data: Map.get(previous || %{}, :probe_data),
      last_ok_at: Map.get(previous || %{}, :last_ok_at)
    }
  end

  defp current_source_snapshot(device_id, source_name) do
    case SnapshotStore.snapshot(device_id) do
      %{sources: sources} when is_map(sources) -> Map.get(sources, source_name)
      _snapshot -> nil
    end
  end

  defp publish_source_snapshot(device, source, source_snapshot, emitted_at) do
    hub_name = {:via, Registry, {NerveCenter.Runtime.DeviceRegistry, device.id}}
    GenServer.cast(hub_name, {:source_update, source.name, source_snapshot})

    Phoenix.PubSub.broadcast(
      NerveCenter.PubSub,
      Topology.source_topic(device.id, source.name),
      %SourceSnapshotUpdated{
        device_id: device.id,
        source: source.name,
        source_snapshot: source_snapshot,
        emitted_at: emitted_at
      }
    )
  end

  defp observed_at(payload) do
    case Map.get(payload, :observed_at) do
      %DateTime{microsecond: {microsecond, _precision}} = observed_at ->
        %{observed_at | microsecond: {microsecond, 6}}

      _other ->
        DateTime.utc_now()
    end
  end

  defp data(%{name: :ha_supervisor}, payload) do
    payload
    |> default_data()
    |> summarize_single_supervisor_addon_error()
  end

  defp data(_source, payload), do: default_data(payload)

  defp default_data(payload), do: Map.get(payload, :data) || %{}

  defp summarize_single_supervisor_addon_error(
         %{
           summary: %{message: "1 Home Assistant Supervisor problem(s) detected."},
           addons: addons
         } = data
       )
       when is_list(addons) do
    case Enum.find(addons, &single_error_addon?/1) do
      %{label: label, state: state} when is_binary(label) and is_binary(state) ->
        put_in(data, [:summary, :message], "#{label} add-on is #{state}.")

      _addon ->
        data
    end
  end

  defp summarize_single_supervisor_addon_error(data), do: data

  defp single_error_addon?(%{required: true, status: :error}), do: true
  defp single_error_addon?(_addon), do: false

  defp sanitize_refresh_error({:auth, status, _body}),
    do: {:auth, status, :manual_refresh_unauthorized}

  defp sanitize_refresh_error({:http, status, _body}),
    do: {:http, status, :manual_refresh_http_error}

  defp sanitize_refresh_error({:invalid_semantic_status, _}),
    do: {:invalid_callback_payload, :invalid_semantic_status}

  defp sanitize_refresh_error({:invalid_callback_payload, :invalid_semantic_status}),
    do: {:invalid_callback_payload, :invalid_semantic_status}

  defp sanitize_refresh_error({:invalid_callback_return, _}),
    do: {:invalid_callback_payload, :invalid_return}

  defp sanitize_refresh_error({:exception, _}), do: {:manual_refresh_failed, :exception}

  defp sanitize_refresh_error({:caught, kind, _}) when kind in @safe_catch_kinds,
    do: {:manual_refresh_failed, {:caught, kind}}

  defp sanitize_refresh_error({:caught, _kind, _reason}), do: {:manual_refresh_failed, :caught}

  defp sanitize_refresh_error({:request, reason}) when reason in @safe_request_reasons,
    do: {:request, reason}

  defp sanitize_refresh_error({:request, _}), do: {:request, :failed}
  defp sanitize_refresh_error(reason) when reason in @safe_callback_error_atoms, do: reason

  defp sanitize_refresh_error(reason) when is_atom(reason),
    do: {:manual_refresh_failed, :callback_error}

  defp sanitize_refresh_error(_reason), do: {:manual_refresh_failed, :callback_error}
end
