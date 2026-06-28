defmodule NerveCenter.TestSupport.PersistenceWriterHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias NerveCenter.Runtime.PersistenceWriter

  @poll_interval_ms 25

  def clear_persistence_writer_queues do
    :sys.replace_state(PersistenceWriter, fn state ->
      %{
        state
        | samples: [],
          sample_count: 0,
          events: [],
          event_count: 0,
          probes: [],
          probe_count: 0
      }
    end)
  end

  def wait_for_persistence_writer_drain(timeout_ms \\ 1_500) do
    wait_until(
      fn ->
        flush_persistence_writer_now()
        persistence_writer_queue_empty?()
      end,
      timeout_ms
    )
  end

  def persistence_writer_queue_empty?, do: persistence_writer_idle?()

  def assert_persistence_count_stable(label, count_fun, expected_count, opts \\ [])
      when is_function(count_fun, 0) and is_integer(expected_count) do
    flush_interval_ms = PersistenceWriter.flush_interval_ms()
    stable_ms = Keyword.get(opts, :stable_ms, flush_interval_ms + 100)
    timeout_ms = Keyword.get(opts, :timeout_ms, stable_ms + flush_interval_ms + 1_000)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_assert_persistence_count_stable(label, count_fun, expected_count, stable_ms, nil, deadline)
  end

  defp do_assert_persistence_count_stable(
         label,
         count_fun,
         expected_count,
         stable_ms,
         stable_since,
         deadline
       ) do
    flush_persistence_writer_now()
    now = System.monotonic_time(:millisecond)
    actual_count = count_fun.()
    idle? = persistence_writer_idle?()

    cond do
      actual_count > expected_count ->
        flunk("expected #{label} to remain at #{expected_count}, got #{actual_count}")

      actual_count == expected_count and idle? and is_nil(stable_since) ->
        sleep_or_timeout(label, count_fun, expected_count, stable_ms, now, deadline)

      actual_count == expected_count and idle? and now - stable_since >= stable_ms ->
        :ok

      actual_count == expected_count and idle? ->
        sleep_or_timeout(label, count_fun, expected_count, stable_ms, stable_since, deadline)

      now >= deadline ->
        flunk(
          "expected #{label} to remain at #{expected_count} with an idle persistence writer for #{stable_ms}ms"
        )

      true ->
        Process.sleep(@poll_interval_ms)

        do_assert_persistence_count_stable(
          label,
          count_fun,
          expected_count,
          stable_ms,
          nil,
          deadline
        )
    end
  end

  defp sleep_or_timeout(label, count_fun, expected_count, stable_ms, stable_since, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk(
        "expected #{label} to remain at #{expected_count} with an idle persistence writer for #{stable_ms}ms"
      )
    else
      Process.sleep(@poll_interval_ms)

      do_assert_persistence_count_stable(
        label,
        count_fun,
        expected_count,
        stable_ms,
        stable_since,
        deadline
      )
    end
  end

  defp flush_persistence_writer_now do
    PersistenceWriter.flush_now()
  end

  defp persistence_writer_idle? do
    PersistenceWriter.queue_depth() == 0 and
      Process.info(Process.whereis(PersistenceWriter), :message_queue_len) ==
        {:message_queue_len, 0}
  end

  def wait_until(fun, timeout_ms \\ 1_500) do
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
        Process.sleep(@poll_interval_ms)
        do_wait_until(fun, deadline)
      end
    end
  end
end
