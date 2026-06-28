defmodule NerveCenter.Runtime.PollingSourceRunner do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Topology

  require Logger

  @allowed_semantic_statuses [:ok, :degraded, :error, :offline, :stale, :unknown]

  def child_spec(opts) do
    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)
    module = Keyword.fetch!(opts, :module)

    %{
      id: {module, device.id, source.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    module = Keyword.fetch!(opts, :module)
    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)
    source_health = AppHealth.source_state(device.id, source.name)
    source_snapshot = source_snapshot(device.id, source.name) || %{}

    state = %{
      module: module,
      device: device,
      source: source,
      interval_ms: Map.get(source, :interval_ms, module.normal_interval_ms()),
      private: %{},
      probe_data: Map.get(source_snapshot, :probe_data),
      last_ok_at: source_health.last_ok_at || Map.get(source_snapshot, :last_ok_at),
      consecutive_failures: source_health.consecutive_failures,
      backoff_ms: source_health.backoff_ms,
      last_error: source_health.last_error,
      last_error_at: source_health.last_error_at,
      ever_ok?:
        not is_nil(source_health.last_ok_at) or Map.get(source_snapshot, :ever_ok?, false),
      last_payload: %{
        metrics: Map.get(source_snapshot, :metrics, %{}),
        data: Map.get(source_snapshot, :data, %{})
      },
      last_status: Map.get(source_snapshot, :status, :unknown),
      last_semantic_status: stored_successful_semantic_status(source_snapshot)
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case remaining_backoff_ms(state) do
      0 ->
        state = run_probe(state)
        {:noreply, poll_now(state)}

      delay_ms ->
        schedule_bootstrap_poll(delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:bootstrap_poll, state) do
    state = run_probe(state)
    {:noreply, poll_now(state)}
  end

  def handle_info(:poll, state) do
    {:noreply, poll_now(state)}
  end

  defp run_probe(state) do
    context = context(state)
    recorded_at = DateTime.utc_now()

    probe_payload =
      case safe_callback(state, :probe, fn -> state.module.probe(context) end) do
        {:ok, payload} -> %{ok: true, data: payload}
        {:error, reason} -> %{ok: false, error: inspect(reason)}
      end

    PersistenceWriter.enqueue_probe(%{
      device_id: Atom.to_string(state.device.id),
      source: Atom.to_string(state.source.name),
      probe_data: probe_payload,
      probed_at: recorded_at
    })

    %{state | probe_data: probe_payload}
  end

  defp poll_now(state) do
    context = context(state)

    case safe_callback(state, :poll, fn -> state.module.poll(context) end) do
      {:ok, raw} ->
        handle_success(state, raw)

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp handle_success(state, raw) do
    context = context(state)

    case safe_callback(state, :normalize, fn -> state.module.normalize(raw, context) end) do
      {:ok, payload} ->
        case safe_step(state, :publish_success, fn -> do_handle_success(state, payload) end) do
          {:ok, {:ok, new_state}} -> new_state
          {:ok, {:error, reason}} -> handle_failure(state, reason)
          {:error, reason} -> handle_failure(state, reason)
        end

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp handle_failure(state, reason) do
    backoff_ms = next_backoff_ms(state, reason)
    AppHealth.record_source_failure(state.device.id, state.source.name, reason, backoff_ms)
    observed_at = DateTime.utc_now()
    status = failure_status(state, reason)

    maybe_log_failure(state, status, reason, backoff_ms)

    source_snapshot = %SourceSnapshot{
      device_id: state.device.id,
      source: state.source.name,
      status: status,
      observed_at: observed_at,
      last_ok_at: state.last_ok_at,
      last_error_at: observed_at,
      last_error: inspect(reason),
      probe_data: state.probe_data,
      consecutive_failures: state.consecutive_failures + 1,
      backoff_ms: backoff_ms,
      ever_ok?: state.ever_ok?,
      metrics: state.last_payload.metrics,
      data: state.last_payload.data
    }

    publish_source_snapshot(state, source_snapshot, observed_at)
    schedule_poll(backoff_ms)

    %{
      state
      | consecutive_failures: state.consecutive_failures + 1,
        backoff_ms: backoff_ms,
        last_error_at: observed_at,
        last_error: inspect(reason),
        last_status: status
    }
  end

  defp do_handle_success(state, payload) do
    with {:ok, semantic_status} <- semantic_status(payload) do
      do_publish_success(state, payload, semantic_status)
    end
  end

  defp do_publish_success(state, payload, semantic_status) do
    observed_at = Map.get(payload, :observed_at, DateTime.utc_now())
    normalized_metrics = Catalog.normalize(Map.get(payload, :metrics, []))
    metric_map = Map.new(normalized_metrics, &{&1.metric_id, &1.metric_value})
    data = Map.get(payload, :data, %{})

    PersistenceWriter.enqueue_samples(
      Enum.map(normalized_metrics, fn metric ->
        %{
          device_id: Atom.to_string(state.device.id),
          source: Atom.to_string(state.source.name),
          metric_name: metric.metric_name,
          metric_value: metric.metric_value / 1,
          recorded_at: observed_at
        }
      end)
    )

    PersistenceWriter.enqueue_events(
      Enum.map(Map.get(payload, :events, []), fn event ->
        %{
          device_id: Atom.to_string(state.device.id),
          source: Atom.to_string(state.source.name),
          event_type: Atom.to_string(Map.fetch!(event, :event_type)),
          message: Map.fetch!(event, :message),
          recorded_at: observed_at
        }
      end)
    )

    source_snapshot = %SourceSnapshot{
      device_id: state.device.id,
      source: state.source.name,
      status: semantic_status,
      observed_at: observed_at,
      last_ok_at: observed_at,
      last_error_at: nil,
      last_error: nil,
      probe_data: state.probe_data,
      consecutive_failures: 0,
      backoff_ms: 0,
      ever_ok?: true,
      metrics: metric_map,
      data: data
    }

    AppHealth.record_source_success(state.device.id, state.source.name, observed_at)
    maybe_log_success(state, semantic_status)
    publish_source_snapshot(state, source_snapshot, observed_at)
    schedule_poll(state.interval_ms)

    {:ok,
     %{
       state
       | private: Map.get(payload, :private, state.private),
         last_ok_at: observed_at,
         consecutive_failures: 0,
         backoff_ms: 0,
         last_error_at: nil,
         ever_ok?: true,
         last_error: nil,
         last_payload: %{metrics: metric_map, data: data},
         last_status: semantic_status,
         last_semantic_status: semantic_status
     }}
  end

  defp semantic_status(payload) do
    case Map.fetch(payload, :status) do
      :error ->
        {:ok, :ok}

      {:ok, nil} ->
        {:ok, :ok}

      {:ok, semantic_status} ->
        if semantic_status in @allowed_semantic_statuses do
          {:ok, semantic_status}
        else
          {:error, {:invalid_callback_payload, :invalid_semantic_status}}
        end
    end
  end

  defp stored_successful_semantic_status(source_snapshot) do
    status = Map.get(source_snapshot, :status)

    if status in @allowed_semantic_statuses and is_nil(Map.get(source_snapshot, :last_error)) and
         is_nil(Map.get(source_snapshot, :last_error_at)) do
      status
    else
      nil
    end
  end

  defp publish_source_snapshot(state, source_snapshot, emitted_at) do
    hub_name = {:via, Registry, {NerveCenter.Runtime.DeviceRegistry, state.device.id}}
    GenServer.cast(hub_name, {:source_update, state.source.name, source_snapshot})

    Phoenix.PubSub.broadcast(
      NerveCenter.PubSub,
      Topology.source_topic(state.device.id, state.source.name),
      %SourceSnapshotUpdated{
        device_id: state.device.id,
        source: state.source.name,
        source_snapshot: source_snapshot,
        emitted_at: emitted_at
      }
    )
  end

  defp context(state) do
    %{
      device: state.device,
      source: state.source,
      interval_ms: state.interval_ms,
      private: state.private,
      probe_data: state.probe_data,
      last_ok_at: state.last_ok_at
    }
  end

  defp next_backoff_ms(state, reason) do
    cond do
      offline_reason?(state, reason) ->
        300_000

      auth_error?(reason) ->
        next_auth_backoff_ms(state)

      true ->
        next_standard_backoff_ms(state)
    end
  end

  defp next_standard_backoff_ms(state) do
    base =
      cond do
        state.backoff_ms > 0 -> min(state.backoff_ms * 2, 300_000)
        true -> min(state.interval_ms, 300_000)
      end

    apply_jitter(base)
  end

  defp next_auth_backoff_ms(state) do
    base =
      cond do
        state.backoff_ms >= 60_000 -> min(state.backoff_ms * 2, 900_000)
        true -> 60_000
      end

    apply_jitter(base)
  end

  defp auth_error?({:auth, _status, _body}), do: true
  defp auth_error?({:auth, _reason}), do: true
  defp auth_error?(_reason), do: false

  defp apply_jitter(base) do
    jitter = round(base * 0.15)
    max(base + :rand.uniform(jitter * 2 + 1) - jitter - 1, 1_000)
  end

  defp failure_status(state, reason) do
    cond do
      offline_reason?(state, reason) and state.ever_ok? ->
        :offline

      not state.ever_ok? ->
        :unknown

      stale?(state) ->
        :stale

      true ->
        :error
    end
  end

  defp offline_reason?(state, reason) do
    state.device.offline_expected and request_error?(reason)
  end

  defp request_error?({:request, _reason}), do: true
  defp request_error?(_reason), do: false

  defp stale?(state) do
    case state.last_ok_at do
      nil ->
        false

      last_ok_at ->
        DateTime.diff(DateTime.utc_now(), last_ok_at, :millisecond) >
          state.module.stale_after_ms()
    end
  end

  defp source_snapshot(device_id, source_name) do
    device_id
    |> SnapshotStore.snapshot()
    |> case do
      %{sources: sources} -> Map.get(sources, source_name)
      _ -> nil
    end
  end

  defp remaining_backoff_ms(%{backoff_ms: 0}), do: 0

  defp remaining_backoff_ms(%{backoff_ms: backoff_ms, last_error_at: %DateTime{} = last_error_at}) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_error_at, :millisecond)
    max(backoff_ms - elapsed_ms, 0)
  end

  defp remaining_backoff_ms(%{backoff_ms: backoff_ms}), do: backoff_ms

  defp safe_callback(state, callback_name, fun) do
    case safe_step(state, callback_name, fun) do
      {:ok, {:ok, _} = ok} ->
        ok

      {:ok, {:error, _} = error} ->
        error

      {:ok, other} ->
        {:error, {:invalid_callback_return, callback_name, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_step(state, label, fun) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.error(
        "polling source #{state.device.id}/#{state.source.name} #{label} crashed: #{Exception.message(error)}"
      )

      {:error, {:callback_crash, label, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error(
        "polling source #{state.device.id}/#{state.source.name} #{label} #{kind}: #{inspect(reason)}"
      )

      {:error, {:callback_crash, label, {kind, reason}}}
  end

  defp maybe_log_failure(state, status, reason, backoff_ms) do
    if state.consecutive_failures == 0 or state.last_status != status do
      Logger.warning(
        "polling source #{state.device.id}/#{state.source.name} entered #{status} " <>
          "backoff=#{backoff_ms}ms last_ok_at=#{format_datetime(state.last_ok_at)} " <>
          "reason=#{inspect(reason)}"
      )
    end
  end

  defp maybe_log_success(state, semantic_status) do
    cond do
      state.consecutive_failures > 0 ->
        Logger.info(
          "polling source #{state.device.id}/#{state.source.name} communication recovered after " <>
            "#{state.consecutive_failures} failures semantic_status=#{semantic_status} " <>
            "last_error=#{state.last_error || "none"}"
        )

      state.last_semantic_status not in [nil, :ok] and semantic_status == :ok ->
        Logger.info(
          "polling source #{state.device.id}/#{state.source.name} semantic status recovered to ok"
        )

      true ->
        :ok
    end
  end

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp schedule_bootstrap_poll(ms) do
    Process.send_after(self(), :bootstrap_poll, ms)
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end
end
