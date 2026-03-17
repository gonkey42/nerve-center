defmodule NerveCenter.Runtime.PollingSourceRunner do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Metrics.Catalog
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Topology

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
    module = Keyword.fetch!(opts, :module)
    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)
    source_health = AppHealth.source_state(device.id, source.name)

    state = %{
      module: module,
      device: device,
      source: source,
      interval_ms: Map.get(source, :interval_ms, module.normal_interval_ms()),
      private: %{},
      probe_data: nil,
      last_ok_at: source_health.last_ok_at,
      consecutive_failures: source_health.consecutive_failures,
      backoff_ms: source_health.backoff_ms,
      last_error: source_health.last_error,
      ever_ok?: not is_nil(source_health.last_ok_at),
      last_payload: %{metrics: %{}, data: %{}}
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    state = run_probe(state)
    {:noreply, poll_now(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, poll_now(state)}
  end

  defp run_probe(state) do
    context = context(state)
    recorded_at = DateTime.utc_now()

    probe_payload =
      case state.module.probe(context) do
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

    case state.module.poll(context) do
      {:ok, raw} ->
        handle_success(state, raw)

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp handle_success(state, raw) do
    context = context(state)

    case state.module.normalize(raw, context) do
      {:ok, payload} ->
        observed_at = Map.get(payload, :observed_at, DateTime.utc_now())
        normalized_metrics = Catalog.normalize(Map.get(payload, :metrics, []))
        metric_map = Map.new(normalized_metrics, &{&1.metric_id, &1.metric_value})

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
          status: :ok,
          observed_at: observed_at,
          last_ok_at: observed_at,
          last_error_at: nil,
          last_error: nil,
          probe_data: state.probe_data,
          consecutive_failures: 0,
          backoff_ms: 0,
          ever_ok?: true,
          metrics: metric_map,
          data: Map.get(payload, :data, %{})
        }

        AppHealth.record_source_success(state.device.id, state.source.name, observed_at)
        publish_source_snapshot(state, source_snapshot, observed_at)

        schedule_poll(state.interval_ms)

        %{
          state
          | private: Map.get(payload, :private, state.private),
            last_ok_at: observed_at,
            consecutive_failures: 0,
            backoff_ms: 0,
            ever_ok?: true,
            last_error: nil,
            last_payload: %{metrics: metric_map, data: Map.get(payload, :data, %{})}
        }

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp handle_failure(state, reason) do
    backoff_ms = next_backoff_ms(state, reason)
    AppHealth.record_source_failure(state.device.id, state.source.name, reason, backoff_ms)
    observed_at = DateTime.utc_now()

    source_snapshot = %SourceSnapshot{
      device_id: state.device.id,
      source: state.source.name,
      status: failure_status(state),
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
        last_error: inspect(reason)
    }
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
    if auth_error?(reason) do
      next_auth_backoff_ms(state)
    else
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

  defp failure_status(state) do
    cond do
      not state.ever_ok? ->
        :unknown

      stale?(state) ->
        :stale

      true ->
        :error
    end
  end

  defp stale?(state) do
    case state.last_ok_at do
      nil ->
        false

      last_ok_at ->
        DateTime.diff(DateTime.utc_now(), last_ok_at, :millisecond) >
          state.module.stale_after_ms()
    end
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end
end
