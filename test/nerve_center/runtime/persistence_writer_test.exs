defmodule NerveCenter.Runtime.PersistenceWriterTest do
  use NerveCenter.DataCase, async: false

  alias NerveCenter.Persistence.DeviceEvent
  alias NerveCenter.Persistence.DeviceHourlyRollup
  alias NerveCenter.Persistence.DeviceSample
  alias NerveCenter.Persistence.SourceProbe
  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.PersistenceWriter

  setup do
    reset_runtime_state()

    Repo.delete_all(DeviceSample)
    Repo.delete_all(DeviceEvent)
    Repo.delete_all(SourceProbe)
    Repo.delete_all(DeviceHourlyRollup)

    :ok
  end

  test "sqlite uses wal mode, busy_timeout, and passes integrity_check" do
    assert %{rows: [["wal"]]} = Repo.query!("PRAGMA journal_mode", [])
    assert %{rows: [[5_000]]} = Repo.query!("PRAGMA busy_timeout", [])
    assert %{rows: [["ok"]]} = Repo.query!("PRAGMA integrity_check", [])
  end

  test "flushes queued samples under load" do
    rows =
      Enum.map(1..250, fn value ->
        %{
          device_id: "load-test",
          source: "polling",
          metric_name: "cpu_util_ratio",
          metric_value: value / 100,
          recorded_at: DateTime.utc_now()
        }
      end)

    PersistenceWriter.enqueue_samples(rows)

    wait_until(fn ->
      count_rows(DeviceSample, "load-test") == 250 and
        AppHealth.snapshot().persistence.queue_depth == 0
    end)

    assert count_rows(DeviceSample, "load-test") == 250
  end

  test "drains a 10,000 message probe burst without leaving backlog behind" do
    row = %{
      device_id: "mailbox-burst",
      source: "polling",
      probe_data: %{ok: true},
      probed_at: DateTime.utc_now()
    }

    Enum.each(1..10_000, fn _ ->
      PersistenceWriter.enqueue_probe(row)
    end)

    writer_pid = Process.whereis(PersistenceWriter)
    assert is_pid(writer_pid)
    assert {:message_queue_len, backlog} = Process.info(writer_pid, :message_queue_len)
    assert backlog > 0

    wait_until(
      fn ->
        count_rows(SourceProbe, "mailbox-burst") == 10_000 and
          Process.info(writer_pid, :message_queue_len) == {:message_queue_len, 0}
      end,
      5_000
    )

    assert count_rows(SourceProbe, "mailbox-burst") == 10_000
    assert Process.info(writer_pid, :message_queue_len) == {:message_queue_len, 0}

    wait_until(fn ->
      AppHealth.snapshot().persistence.queue_depth == 0
    end)
  end

  test "maintenance prunes expired rows and rolls up old samples" do
    triggered_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    old_sample_base = DateTime.add(triggered_at, -8 * 86_400, :second)

    old_sample_time =
      DateTime.new!(
        DateTime.to_date(old_sample_base),
        Time.new!(old_sample_base.hour, 10, 0, {0, 6}),
        "Etc/UTC"
      )

    recent_sample_time = DateTime.add(triggered_at, -1_800, :second)

    Repo.insert_all(DeviceSample, [
      %{
        device_id: "retention-test",
        source: "polling",
        metric_name: "cpu_util_ratio",
        metric_value: 0.2,
        recorded_at: old_sample_time
      },
      %{
        device_id: "retention-test",
        source: "polling",
        metric_name: "cpu_util_ratio",
        metric_value: 0.6,
        recorded_at: DateTime.add(old_sample_time, 5 * 60, :second)
      },
      %{
        device_id: "retention-test",
        source: "polling",
        metric_name: "cpu_util_ratio",
        metric_value: 0.9,
        recorded_at: recent_sample_time
      }
    ])

    Repo.insert_all(SourceProbe, [
      %{
        device_id: "retention-test",
        source: "polling",
        probe_data: %{ok: true},
        probed_at: DateTime.add(triggered_at, -8 * 86_400, :second)
      },
      %{
        device_id: "retention-test",
        source: "polling",
        probe_data: %{ok: true},
        probed_at: DateTime.add(triggered_at, -60, :second)
      }
    ])

    Repo.insert_all(DeviceEvent, [
      %{
        device_id: "retention-test",
        source: "polling",
        event_type: "offline",
        message: "old",
        recorded_at: DateTime.add(triggered_at, -91 * 86_400, :second)
      },
      %{
        device_id: "retention-test",
        source: "polling",
        event_type: "offline",
        message: "recent",
        recorded_at: DateTime.add(triggered_at, -60, :second)
      }
    ])

    Repo.insert_all(DeviceHourlyRollup, [
      %{
        device_id: "retention-test",
        source: "polling",
        metric_name: "cpu_util_ratio",
        avg_value: 0.4,
        min_value: 0.1,
        max_value: 0.8,
        sample_count: 3,
        bucket_start_at: DateTime.add(triggered_at, -31 * 86_400, :second)
      }
    ])

    PersistenceWriter.run_maintenance(triggered_at)

    wait_until(fn ->
      count_rows(DeviceSample, "retention-test") == 1 and
        count_rows(SourceProbe, "retention-test") == 1 and
        count_rows(DeviceEvent, "retention-test") == 1 and
        count_rows(DeviceHourlyRollup, "retention-test") == 1 and
        AppHealth.snapshot().retention.status == :ok
    end)

    assert count_rows(DeviceSample, "retention-test") == 1
    assert count_rows(SourceProbe, "retention-test") == 1
    assert count_rows(DeviceEvent, "retention-test") == 1

    rollup =
      Repo.one!(from(rollup in DeviceHourlyRollup, where: rollup.device_id == "retention-test"))

    assert rollup.sample_count == 2
    assert rollup.min_value == 0.2
    assert rollup.max_value == 0.6
    assert_in_delta rollup.avg_value, 0.4, 0.0001
  end

  test "maintenance does not duplicate an existing hourly rollup for the same bucket" do
    triggered_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    old_sample_time = DateTime.add(triggered_at, -8 * 86_400, :second)

    Repo.insert_all(DeviceSample, [
      %{
        device_id: "existing-rollup",
        source: "polling",
        metric_name: "cpu_util_ratio",
        metric_value: 0.5,
        recorded_at: old_sample_time
      }
    ])

    bucket_start_at =
      DateTime.new!(
        DateTime.to_date(old_sample_time),
        Time.new!(old_sample_time.hour, 0, 0, {0, 6}),
        "Etc/UTC"
      )

    Repo.insert!(%DeviceHourlyRollup{
      device_id: "existing-rollup",
      source: "polling",
      metric_name: "cpu_util_ratio",
      avg_value: 0.5,
      min_value: 0.5,
      max_value: 0.5,
      sample_count: 1,
      bucket_start_at: bucket_start_at
    })

    PersistenceWriter.run_maintenance(triggered_at)

    wait_until(fn ->
      count_rows(DeviceSample, "existing-rollup") == 0 and
        count_rows(DeviceHourlyRollup, "existing-rollup") == 1 and
        AppHealth.snapshot().retention.status == :ok
    end)

    assert count_rows(DeviceSample, "existing-rollup") == 0
    assert count_rows(DeviceHourlyRollup, "existing-rollup") == 1
  end

  defp count_rows(schema, device_id) do
    Repo.aggregate(from(row in schema, where: row.device_id == ^device_id), :count, :id)
  end

  defp reset_runtime_state do
    :sys.replace_state(PersistenceWriter, fn state ->
      %{
        state
        | samples: [],
          sample_count: 0,
          events: [],
          event_count: 0,
          probes: [],
          probe_count: 0,
          maintenance: :idle
      }
    end)

    :sys.replace_state(AppHealth, fn state ->
      %{
        state
        | persistence: %{queue_depth: 0, last_flush_at: nil},
          retention: %{status: :never_run, at: nil, message: nil}
      }
    end)
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        Process.sleep(25)
        do_wait_until(fun, deadline)
      end
    end
  end
end
