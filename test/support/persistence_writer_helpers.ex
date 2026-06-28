defmodule NerveCenter.TestSupport.PersistenceWriterHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias NerveCenter.Runtime.PersistenceWriter

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
    wait_until(&persistence_writer_queue_empty?/0, timeout_ms)
  end

  def persistence_writer_queue_empty? do
    state = :sys.get_state(PersistenceWriter)
    state.sample_count == 0 and state.event_count == 0 and state.probe_count == 0
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
        Process.sleep(25)
        do_wait_until(fun, deadline)
      end
    end
  end
end
