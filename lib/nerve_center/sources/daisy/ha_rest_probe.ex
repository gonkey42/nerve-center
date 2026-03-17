defmodule NerveCenter.Sources.Daisy.HARestProbe do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.SourceSnapshotUpdated
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.SourceSnapshot
  alias NerveCenter.Sources.Support
  alias NerveCenter.Topology

  require Logger

  def child_spec(opts) do
    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)

    %{
      id: {__MODULE__, device.id, source.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def required_env, do: ["HA_TOKEN"]

  @impl true
  def init(opts) do
    Process.flag(:message_queue_data, :off_heap)

    device = Keyword.fetch!(opts, :device)
    source = Keyword.fetch!(opts, :source)
    source_health = AppHealth.source_state(device.id, source.name)
    source_snapshot = source_snapshot(device.id, source.name) || %{}

    state = %{
      device: device,
      source: source,
      interval_ms: Map.get(source, :interval_ms, 300_000),
      probe_data: Map.get(source_snapshot, :probe_data),
      last_ok_at: source_health.last_ok_at || Map.get(source_snapshot, :last_ok_at),
      consecutive_failures: source_health.consecutive_failures,
      backoff_ms: source_health.backoff_ms,
      last_error: source_health.last_error,
      last_error_at: source_health.last_error_at,
      ever_ok?:
        not is_nil(source_health.last_ok_at) or Map.get(source_snapshot, :ever_ok?, false),
      last_payload: Map.get(source_snapshot, :data, %{}),
      last_status: Map.get(source_snapshot, :status, :unknown)
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case remaining_backoff_ms(state) do
      0 ->
        {:noreply, poll_now(state)}

      delay_ms ->
        schedule_poll(delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, poll_now(state)}
  end

  defp poll_now(state) do
    observed_at = DateTime.utc_now()

    case safe_probe(state.device) do
      {:ok, payload} ->
        handle_success(state, payload, observed_at)

      {:error, reason} ->
        handle_failure(state, reason, observed_at)
    end
  end

  defp handle_success(state, payload, observed_at) do
    probe_data = %{ok: true, data: payload}
    data = Map.put(payload, :connected?, true)

    PersistenceWriter.enqueue_probe(%{
      device_id: Atom.to_string(state.device.id),
      source: Atom.to_string(state.source.name),
      probe_data: probe_data,
      probed_at: observed_at
    })

    AppHealth.record_source_success(state.device.id, state.source.name, observed_at)
    maybe_log_recovery(state)

    publish_source_snapshot(
      state,
      %SourceSnapshot{
        device_id: state.device.id,
        source: state.source.name,
        status: :ok,
        observed_at: observed_at,
        last_ok_at: observed_at,
        last_error_at: nil,
        last_error: nil,
        probe_data: probe_data,
        consecutive_failures: 0,
        backoff_ms: 0,
        ever_ok?: true,
        metrics: %{},
        data: data
      },
      observed_at
    )

    schedule_poll(state.interval_ms)

    %{
      state
      | probe_data: probe_data,
        last_ok_at: observed_at,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error: nil,
        last_error_at: nil,
        ever_ok?: true,
        last_payload: data,
        last_status: :ok
    }
  end

  defp handle_failure(state, reason, observed_at) do
    backoff_ms = next_backoff_ms(state, reason)
    probe_data = %{ok: false, error: inspect(reason)}
    status = failure_status(state, reason)
    data = Map.put(state.last_payload, :connected?, false)

    PersistenceWriter.enqueue_probe(%{
      device_id: Atom.to_string(state.device.id),
      source: Atom.to_string(state.source.name),
      probe_data: probe_data,
      probed_at: observed_at
    })

    AppHealth.record_source_failure(state.device.id, state.source.name, reason, backoff_ms)
    maybe_log_failure(state, status, reason, backoff_ms)

    publish_source_snapshot(
      state,
      %SourceSnapshot{
        device_id: state.device.id,
        source: state.source.name,
        status: status,
        observed_at: observed_at,
        last_ok_at: state.last_ok_at,
        last_error_at: observed_at,
        last_error: inspect(reason),
        probe_data: probe_data,
        consecutive_failures: state.consecutive_failures + 1,
        backoff_ms: backoff_ms,
        ever_ok?: state.ever_ok?,
        metrics: %{},
        data: data
      },
      observed_at
    )

    schedule_poll(backoff_ms)

    %{
      state
      | probe_data: probe_data,
        consecutive_failures: state.consecutive_failures + 1,
        backoff_ms: backoff_ms,
        last_error: inspect(reason),
        last_error_at: observed_at,
        last_payload: data,
        last_status: status
    }
  end

  defp safe_probe(device) do
    probe(device)
  rescue
    error ->
      Logger.error("ha rest probe #{device.id} crashed: #{Exception.message(error)}")

      {:error, {:callback_crash, :probe, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error("ha rest probe #{device.id} #{kind}: #{inspect(reason)}")

      {:error, {:callback_crash, :probe, {kind, reason}}}
  end

  defp maybe_log_failure(state, status, reason, backoff_ms) do
    if state.consecutive_failures == 0 or state.last_status != status do
      Logger.warning(
        "ha rest probe #{state.device.id}/#{state.source.name} entered #{status} " <>
          "backoff=#{backoff_ms}ms last_ok_at=#{format_datetime(state.last_ok_at)} " <>
          "reason=#{inspect(reason)}"
      )
    end
  end

  defp maybe_log_recovery(state) do
    if state.consecutive_failures > 0 or state.last_status != :ok do
      Logger.info(
        "ha rest probe #{state.device.id}/#{state.source.name} recovered after " <>
          "#{state.consecutive_failures} failures last_error=#{state.last_error || "none"}"
      )
    end
  end

  defp next_backoff_ms(state, reason) do
    cond do
      auth_error?(reason) ->
        next_auth_backoff_ms(state.backoff_ms)

      true ->
        next_standard_backoff_ms(state)
    end
  end

  defp next_standard_backoff_ms(state) do
    cond do
      state.backoff_ms > 0 -> min(state.backoff_ms * 2, 300_000)
      true -> min(state.interval_ms, 300_000)
    end
  end

  defp next_auth_backoff_ms(current_backoff) when current_backoff < 60_000, do: 60_000
  defp next_auth_backoff_ms(current_backoff), do: min(current_backoff * 2, 900_000)

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

  defp auth_error?({:auth, _reason}), do: true
  defp auth_error?({:auth, _status, _body}), do: true
  defp auth_error?(_reason), do: false

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
          max(state.interval_ms * 3, 90_000)
    end
  end

  defp remaining_backoff_ms(%{backoff_ms: 0}), do: 0

  defp remaining_backoff_ms(%{backoff_ms: backoff_ms, last_error_at: %DateTime{} = last_error_at}) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_error_at, :millisecond)
    max(backoff_ms - elapsed_ms, 0)
  end

  defp remaining_backoff_ms(%{backoff_ms: backoff_ms}), do: backoff_ms

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp source_snapshot(device_id, source_name) do
    device_id
    |> SnapshotStore.snapshot()
    |> case do
      %{sources: sources} -> Map.get(sources, source_name)
      _ -> nil
    end
  end

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp probe(device) do
    with {:ok, config} <-
           Support.request_json("#{device.home_assistant_base_url}/api/config",
             headers: [{"authorization", "Bearer #{System.fetch_env!("HA_TOKEN")}"}]
           ) do
      {:ok,
       %{
         location_name: config["location_name"],
         version: config["version"],
         state: config["state"],
         time_zone: config["time_zone"],
         temperature_unit: get_in(config, ["unit_system", "temperature"]),
         components_loaded: length(config["components"] || [])
       }}
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
end
