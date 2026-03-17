defmodule NerveCenter.Runtime.PersistenceWriter do
  @moduledoc false

  use GenServer

  alias NerveCenter.Repo
  alias NerveCenter.Runtime.AppHealth

  @flush_interval_ms 1_000
  @flush_threshold 200
  @retention_chunk_size 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enqueue_samples(rows) when rows == [], do: :ok
  def enqueue_samples(rows), do: GenServer.cast(__MODULE__, {:enqueue_samples, rows})

  def enqueue_events(rows) when rows == [], do: :ok
  def enqueue_events(rows), do: GenServer.cast(__MODULE__, {:enqueue_events, rows})

  def enqueue_probe(row), do: GenServer.cast(__MODULE__, {:enqueue_probe, row})

  def run_maintenance(triggered_at),
    do: GenServer.cast(__MODULE__, {:run_maintenance, triggered_at})

  @impl true
  def init(_state) do
    schedule_flush()

    {:ok,
     %{
       samples: [],
       events: [],
       probes: [],
       maintenance: :idle
     }}
  end

  @impl true
  def handle_cast({:enqueue_samples, rows}, state) do
    new_state = %{state | samples: state.samples ++ rows}
    maybe_flush(new_state)
  end

  def handle_cast({:enqueue_events, rows}, state) do
    new_state = %{state | events: state.events ++ rows}
    maybe_flush(new_state)
  end

  def handle_cast({:enqueue_probe, row}, state) do
    new_state = %{state | probes: state.probes ++ [row]}
    maybe_flush(new_state)
  end

  def handle_cast({:run_maintenance, triggered_at}, %{maintenance: :idle} = state) do
    send(self(), {:maintenance_step, build_maintenance_steps(triggered_at)})
    {:noreply, %{state | maintenance: :running}}
  end

  def handle_cast({:run_maintenance, _triggered_at}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush()
    {:noreply, flush_queue(state)}
  end

  def handle_info({:maintenance_step, []}, state) do
    AppHealth.record_retention(:ok, DateTime.utc_now())
    {:noreply, %{state | maintenance: :idle}}
  rescue
    error ->
      AppHealth.record_retention(:error, DateTime.utc_now(), inspect(error))
      {:noreply, %{state | maintenance: :idle}}
  end

  def handle_info({:maintenance_step, [step | remaining]}, state) do
    state = flush_queue(state)

    case run_maintenance_step(step) do
      :done ->
        send(self(), {:maintenance_step, remaining})

      {:repeat, next_step} ->
        Process.send_after(self(), {:maintenance_step, [next_step | remaining]}, 50)
    end

    {:noreply, state}
  rescue
    error ->
      AppHealth.record_retention(:error, DateTime.utc_now(), inspect(error))
      {:noreply, %{state | maintenance: :idle}}
  end

  defp maybe_flush(state) do
    AppHealth.record_persistence(queue_depth(state))

    if queue_depth(state) >= @flush_threshold do
      {:noreply, flush_queue(state)}
    else
      {:noreply, state}
    end
  end

  defp flush_queue(state) do
    if queue_depth(state) == 0 do
      state
    else
      insert_all(NerveCenter.Persistence.DeviceSample, state.samples)
      insert_all(NerveCenter.Persistence.DeviceEvent, state.events)
      insert_all(NerveCenter.Persistence.SourceProbe, state.probes)
      flushed_at = DateTime.utc_now()
      AppHealth.record_persistence(0, flushed_at)
      %{state | samples: [], events: [], probes: []}
    end
  end

  defp insert_all(_table, []), do: :ok
  defp insert_all(table, rows), do: Repo.insert_all(table, rows)

  defp queue_depth(state) do
    length(state.samples) + length(state.events) + length(state.probes)
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp build_maintenance_steps(triggered_at) do
    [
      {:rollups, DateTime.add(triggered_at, -3_600, :second)},
      {:delete_batches, "device_samples", "recorded_at",
       DateTime.add(triggered_at, -7 * 86_400, :second)},
      {:delete_batches, "device_hourly_rollups", "bucket_start_at",
       DateTime.add(triggered_at, -30 * 86_400, :second)},
      {:delete_batches, "device_events", "recorded_at",
       DateTime.add(triggered_at, -90 * 86_400, :second)}
    ]
  end

  defp run_maintenance_step({:rollups, cutoff}) do
    cutoff_iso = DateTime.to_iso8601(cutoff)

    Repo.query!(
      """
      INSERT INTO device_hourly_rollups
        (device_id, source, metric_name, avg_value, min_value, max_value, sample_count, bucket_start_at)
      SELECT
        s.device_id,
        s.source,
        s.metric_name,
        AVG(s.metric_value),
        MIN(s.metric_value),
        MAX(s.metric_value),
        COUNT(*),
        strftime('%Y-%m-%dT%H:00:00Z', s.recorded_at)
      FROM device_samples AS s
      WHERE s.recorded_at < ?
        AND NOT EXISTS (
          SELECT 1
          FROM device_hourly_rollups AS r
          WHERE r.device_id = s.device_id
            AND r.source = s.source
            AND r.metric_name = s.metric_name
            AND r.bucket_start_at = strftime('%Y-%m-%dT%H:00:00Z', s.recorded_at)
        )
      GROUP BY
        s.device_id,
        s.source,
        s.metric_name,
        strftime('%Y-%m-%dT%H:00:00Z', s.recorded_at)
      """,
      [cutoff_iso]
    )

    :done
  end

  defp run_maintenance_step({:delete_batches, table, column, cutoff}) do
    cutoff_iso = DateTime.to_iso8601(cutoff)

    result =
      Repo.query!(
        """
        DELETE FROM #{table}
        WHERE id IN (
          SELECT id FROM #{table}
          WHERE #{column} < ?
          LIMIT #{@retention_chunk_size}
        )
        """,
        [cutoff_iso]
      )

    if result.num_rows >= @retention_chunk_size do
      {:repeat, {:delete_batches, table, column, cutoff}}
    else
      :done
    end
  end
end
