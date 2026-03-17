defmodule NerveCenter.Runtime.StreamingSourceRunner do
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

  @streaming_backoff_ms [1_000, 2_000, 5_000, 10_000, 30_000, 60_000]
  @heartbeat_interval_ms 30_000

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

    schedule_heartbeat()

    state = %{
      module: module,
      device: device,
      source: source,
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
      conn: nil,
      websocket: nil,
      request_ref: nil,
      upgrade_status: nil,
      upgrade_headers: [],
      reconnect_timer: nil,
      last_frame_at: nil
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case remaining_backoff_ms(state) do
      0 ->
        state = run_probe(state)
        {:noreply, connect_now(state)}

      delay_ms ->
        {:noreply, %{state | reconnect_timer: schedule_reconnect(delay_ms)}}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    schedule_heartbeat()

    state =
      cond do
        disconnected?(state) ->
          state

        stale?(state) ->
          handle_failure(state, :stale_timeout)

        true ->
          send_frame(state, :ping)
      end

    {:noreply, state}
  end

  def handle_info({:reconnect, timer_ref}, %{reconnect_timer: timer_ref} = state) do
    {:noreply, connect_now(%{state | reconnect_timer: nil})}
  end

  def handle_info({:reconnect, _timer_ref}, state) do
    {:noreply, state}
  end

  def handle_info(_message, %{conn: nil} = state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      :unknown ->
        {:noreply, state}

      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        case process_responses(state, responses) do
          {:ok, state} -> {:noreply, state}
          {:disconnect, state, reason} -> {:noreply, handle_failure(state, reason)}
        end

      {:error, conn, reason, responses} ->
        state = %{state | conn: conn}

        case process_responses(state, responses) do
          {:ok, state} -> {:noreply, handle_failure(state, reason)}
          {:disconnect, state, frame_reason} -> {:noreply, handle_failure(state, frame_reason)}
        end
    end
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

  defp connect_now(state) do
    case safe_callback(state, :connect, fn -> state.module.connect(context(state)) end) do
      {:ok, spec} ->
        case safe_step(state, :connect_socket, fn -> do_connect(state, spec) end) do
          {:ok, new_state} -> new_state
          {:error, reason} -> handle_failure(state, reason)
        end

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp process_responses(state, responses) do
    Enum.reduce_while(responses, {:ok, state}, fn response, {:ok, state} ->
      case process_response(state, response) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:disconnect, state, reason} -> {:halt, {:disconnect, state, reason}}
      end
    end)
  end

  defp process_response(state, {:status, request_ref, status})
       when state.request_ref == request_ref do
    {:ok, %{state | upgrade_status: status}}
  end

  defp process_response(state, {:headers, request_ref, headers})
       when state.request_ref == request_ref do
    {:ok, %{state | upgrade_headers: headers}}
  end

  defp process_response(state, {:done, request_ref}) when state.request_ref == request_ref do
    case Mint.WebSocket.new(state.conn, request_ref, state.upgrade_status, state.upgrade_headers) do
      {:ok, conn, websocket} ->
        {:ok,
         %{
           state
           | conn: conn,
             websocket: websocket,
             upgrade_status: nil,
             upgrade_headers: [],
             last_frame_at: DateTime.utc_now()
         }}

      {:error, conn, reason} ->
        {:disconnect, %{state | conn: conn}, reason}
    end
  end

  defp process_response(state, {:data, request_ref, data})
       when state.request_ref == request_ref and not is_nil(state.websocket) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        process_frames(state, frames)

      {:error, websocket, reason} ->
        {:disconnect, %{state | websocket: websocket}, reason}
    end
  end

  defp process_response(state, {:data, request_ref, _data})
       when state.request_ref == request_ref do
    {:ok, state}
  end

  defp process_response(state, _response), do: {:ok, state}

  defp process_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      case process_frame(state, frame) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:disconnect, state, reason} -> {:halt, {:disconnect, state, reason}}
      end
    end)
  end

  defp process_frame(state, {:text, payload}) do
    state = %{state | last_frame_at: DateTime.utc_now()}

    with {:ok, decoded} <- Jason.decode(payload),
         {:ok, result} <-
           safe_callback(state, :handle_frame, fn ->
             state.module.handle_frame(decoded, context(state))
           end),
         {:ok, state} <- apply_frame_result(state, result) do
      {:ok, state}
    else
      {:error, reason} ->
        {:disconnect, state, reason}
    end
  end

  defp process_frame(state, {:ping, payload}) do
    state =
      state
      |> Map.put(:last_frame_at, DateTime.utc_now())
      |> send_frame({:pong, payload})

    {:ok, state}
  end

  defp process_frame(state, {:pong, _payload}) do
    {:ok, %{state | last_frame_at: DateTime.utc_now()}}
  end

  defp process_frame(state, {:close, code, reason}) do
    {:disconnect, state, {:remote_close, code, reason}}
  end

  defp process_frame(state, {:binary, _payload}) do
    {:disconnect, state, :unexpected_binary_frame}
  end

  defp apply_frame_result(state, result) do
    state = %{state | private: Map.get(result, :private, state.private)}

    with {:ok, state} <- send_outbound_frames(state, Map.get(result, :outbound, [])),
         {:ok, state} <- maybe_publish_success(state, Map.get(result, :snapshot)) do
      {:ok, state}
    end
  end

  defp send_outbound_frames(state, outbound) do
    Enum.reduce_while(outbound, {:ok, state}, fn payload, {:ok, state} ->
      case Jason.encode(payload) do
        {:ok, text} ->
          {:cont, {:ok, send_frame(state, {:text, text})}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_publish_success(state, nil), do: {:ok, state}

  defp maybe_publish_success(state, payload) do
    safe_step(state, :publish_success, fn -> do_publish_success(state, payload) end)
  end

  defp handle_failure(state, reason) do
    {state, reason} = apply_disconnect_callback(state, reason)
    safe_close(state.conn)

    backoff_ms = next_backoff_ms(state.backoff_ms)
    observed_at = DateTime.utc_now()
    last_payload_data = Map.put(state.last_payload.data, :connected?, false)

    source_snapshot = %SourceSnapshot{
      device_id: state.device.id,
      source: state.source.name,
      status: failure_status(state, reason),
      observed_at: observed_at,
      last_ok_at: state.last_ok_at,
      last_error_at: observed_at,
      last_error: inspect(reason),
      probe_data: state.probe_data,
      consecutive_failures: state.consecutive_failures + 1,
      backoff_ms: backoff_ms,
      ever_ok?: state.ever_ok?,
      metrics: state.last_payload.metrics,
      data: last_payload_data
    }

    AppHealth.record_source_failure(state.device.id, state.source.name, reason, backoff_ms)
    publish_source_snapshot(state, source_snapshot, observed_at)

    timer_ref = schedule_reconnect(backoff_ms)

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        upgrade_status: nil,
        upgrade_headers: [],
        reconnect_timer: timer_ref,
        consecutive_failures: state.consecutive_failures + 1,
        backoff_ms: backoff_ms,
        last_error_at: observed_at,
        last_error: inspect(reason),
        last_payload: %{state.last_payload | data: last_payload_data},
        last_frame_at: nil
    }
  end

  defp apply_disconnect_callback(state, reason) do
    case safe_callback(state, :handle_disconnect, fn ->
           state.module.handle_disconnect(reason, context(state))
         end) do
      {:ok, result} ->
        private = Map.get(result, :private, state.private)
        mapped_reason = Map.get(result, :reason, reason)
        {%{state | private: private}, mapped_reason}

      {:error, callback_reason} ->
        {state, callback_reason}
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
      private: state.private,
      probe_data: state.probe_data,
      last_ok_at: state.last_ok_at,
      last_payload: state.last_payload
    }
  end

  defp send_frame(%{websocket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, websocket, reason} ->
        Logger.warning("streaming source frame encode failed: #{inspect(reason)}")
        %{state | websocket: websocket}

      {:error, reason} ->
        Logger.warning("streaming source frame send failed: #{inspect(reason)}")
        state
    end
  end

  defp disconnected?(state), do: is_nil(state.conn) or is_nil(state.websocket)

  defp stale?(state) do
    case state.last_frame_at do
      nil ->
        false

      last_frame_at ->
        DateTime.diff(DateTime.utc_now(), last_frame_at, :millisecond) >
          state.module.stale_after_ms()
    end
  end

  defp do_connect(state, spec) do
    headers = Map.get(spec, :headers, [])

    with {:ok, conn} <-
           Mint.HTTP.connect(spec.transport_scheme, spec.host, spec.port,
             mode: :active,
             protocols: [:http1]
           ),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(spec.scheme, conn, spec.path, headers) do
      %{
        state
        | conn: conn,
          request_ref: request_ref,
          upgrade_status: nil,
          upgrade_headers: [],
          private: Map.get(spec, :private, state.private),
          last_frame_at: DateTime.utc_now(),
          backoff_ms: 0,
          last_error: nil
      }
    else
      {:error, conn, reason} ->
        safe_close(conn)
        handle_failure(%{state | conn: nil}, reason)

      {:error, reason} ->
        handle_failure(state, reason)
    end
  end

  defp do_publish_success(state, payload) do
    observed_at = Map.get(payload, :observed_at, DateTime.utc_now())
    normalized_metrics = Catalog.normalize(Map.get(payload, :metrics, []))
    metric_map = Map.new(normalized_metrics, &{&1.metric_id, &1.metric_value})
    data = payload |> Map.get(:data, %{}) |> Map.put_new(:connected?, true)

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
      data: data
    }

    AppHealth.record_source_success(state.device.id, state.source.name, observed_at)
    publish_source_snapshot(state, source_snapshot, observed_at)

    %{
      state
      | last_ok_at: observed_at,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error_at: nil,
        ever_ok?: true,
        last_error: nil,
        last_payload: %{metrics: metric_map, data: data}
    }
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
        "streaming source #{state.device.id}/#{state.source.name} #{label} crashed: #{Exception.message(error)}"
      )

      {:error, {:callback_crash, label, Exception.message(error)}}
  catch
    kind, reason ->
      Logger.error(
        "streaming source #{state.device.id}/#{state.source.name} #{label} #{kind}: #{inspect(reason)}"
      )

      {:error, {:callback_crash, label, {kind, reason}}}
  end

  defp next_backoff_ms(0), do: hd(@streaming_backoff_ms)

  defp next_backoff_ms(current_backoff) do
    Enum.find(@streaming_backoff_ms, List.last(@streaming_backoff_ms), &(&1 > current_backoff))
  end

  defp failure_status(state, :stale_timeout) when state.ever_ok?, do: :stale
  defp failure_status(state, _reason) when not state.ever_ok?, do: :unknown
  defp failure_status(_state, _reason), do: :error

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
  end

  defp schedule_reconnect(ms) do
    timer_ref = make_ref()
    Process.send_after(self(), {:reconnect, timer_ref}, ms)
    timer_ref
  end

  defp safe_close(nil), do: :ok

  defp safe_close(conn) do
    Mint.HTTP.close(conn)
  rescue
    _ -> :ok
  end
end
