defmodule NerveCenter.TestSupport.DaisyRuntimeHelpers do
  @moduledoc false

  import ExUnit.Callbacks

  alias NerveCenter.Runtime.AppHealth
  alias NerveCenter.Runtime.DeviceHub
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.TestSupport.PersistenceWriterHelpers

  def prepare_daisy_runtime(device, opts \\ []) do
    source_name = Keyword.get(opts, :source_name, :ha_supervisor)
    previous_snapshot = SnapshotStore.snapshot(device.id)
    previous_hub_state = current_hub_state(device.id)
    previous_health = AppHealth.source_state(device.id, source_name)
    suspended_runner = suspend_source_runner(device.id, source_name)
    cleanup = Keyword.get(opts, :cleanup, fn -> :ok end)

    snapshot = Keyword.get(opts, :snapshot, device_snapshot(device))
    source_state = Keyword.get(opts, :source_state, source_health(device.id, source_name))

    restore_app_health(device.id, source_name, source_state)
    SnapshotStore.put(snapshot)
    seed_device_hub(device, snapshot)

    on_exit(fn ->
      resume_source_runner(suspended_runner)
      PersistenceWriterHelpers.clear_persistence_writer_queues()
      cleanup.()

      if previous_snapshot do
        SnapshotStore.put(previous_snapshot)
      end

      restore_device_hub(device.id, previous_hub_state)
      restore_app_health(device.id, source_name, previous_health)
    end)

    :ok
  end

  def device_snapshot(device, overrides \\ %{}) do
    Map.merge(
      %DeviceSnapshot{
        device_id: device.id,
        label: device.label,
        status: :unknown,
        updated_at: nil,
        offline_expected: device.offline_expected,
        metrics: %{},
        sources: %{}
      },
      overrides
    )
  end

  def source_health(device_id, source_name, overrides \\ %{}) do
    Map.merge(
      %{
        device_id: device_id,
        source: source_name,
        last_ok_at: nil,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error_at: nil,
        last_error: nil
      },
      overrides
    )
  end

  defp seed_device_hub(device, snapshot) do
    case Registry.lookup(NerveCenter.Runtime.DeviceRegistry, device.id) do
      [{pid, _value}] ->
        :sys.replace_state(pid, &%{&1 | snapshot: snapshot})

      [] ->
        start_supervised!({DeviceHub, device: device})
    end
  end

  defp current_hub_state(device_id) do
    case Registry.lookup(NerveCenter.Runtime.DeviceRegistry, device_id) do
      [{pid, _value}] -> {:ok, pid, :sys.get_state(pid)}
      [] -> :missing
    end
  end

  defp restore_device_hub(_device_id, {:ok, pid, state}) do
    if Process.alive?(pid) do
      :sys.replace_state(pid, fn _current -> state end)
    end
  end

  defp restore_device_hub(_device_id, :missing), do: :ok

  defp restore_app_health(device_id, source_name, source_state) do
    :sys.replace_state(AppHealth, fn state ->
      %{state | sources: Map.put(state.sources, {device_id, source_name}, source_state)}
    end)
  end

  defp suspend_source_runner(device_id, source_name) do
    case :global.whereis_name({:device_tree, device_id}) do
      :undefined ->
        nil

      tree_pid ->
        tree_pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {{_module, ^device_id, ^source_name}, pid, _type, _modules} when is_pid(pid) ->
            :sys.suspend(pid)
            pid

          _child ->
            nil
        end)
    end
  catch
    :exit, _reason -> nil
  end

  defp resume_source_runner(nil), do: :ok

  defp resume_source_runner(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      :sys.resume(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
