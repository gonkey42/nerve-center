defmodule NerveCenter.Runtime.AppHealth do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.AppHealthUpdated
  alias NerveCenter.Release
  alias NerveCenter.Topology

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  def migration_success? do
    snapshot().migration.status == :ok
  end

  def source_state(device_id, source_name) do
    snapshot().sources[{device_id, source_name}] ||
      %{
        device_id: device_id,
        source: source_name,
        last_ok_at: nil,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error_at: nil,
        last_error: nil
      }
  end

  def record_source_success(device_id, source_name, observed_at) do
    GenServer.cast(__MODULE__, {:source_success, device_id, source_name, observed_at})
  end

  def record_source_failure(device_id, source_name, error, backoff_ms) do
    GenServer.cast(__MODULE__, {:source_failure, device_id, source_name, error, backoff_ms})
  end

  def record_persistence(queue_depth, last_flush_at \\ nil) do
    GenServer.cast(__MODULE__, {:persistence, queue_depth, last_flush_at})
  end

  def record_retention(result, at, message \\ nil) do
    GenServer.cast(__MODULE__, {:retention, result, at, message})
  end

  @impl true
  def init(_state) do
    migration = Release.last_migration_result()
    release_version = Application.spec(:nerve_center, :vsn) |> to_string()

    state = %{
      release_version: release_version,
      boot_time: DateTime.utc_now(),
      migration: migration,
      persistence: %{queue_depth: 0, last_flush_at: nil},
      retention: %{status: :never_run, at: nil, message: nil},
      sources: seed_sources()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:source_success, device_id, source_name, observed_at}, state) do
    source_state =
      state.sources
      |> Map.fetch!({device_id, source_name})
      |> Map.merge(%{
        last_ok_at: observed_at,
        consecutive_failures: 0,
        backoff_ms: 0,
        last_error_at: nil,
        last_error: nil
      })

    new_state = put_in(state.sources[{device_id, source_name}], source_state)
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:source_failure, device_id, source_name, error, backoff_ms}, state) do
    now = DateTime.utc_now()

    source_state =
      state.sources
      |> Map.fetch!({device_id, source_name})
      |> Map.update!(:consecutive_failures, &(&1 + 1))
      |> Map.merge(%{
        backoff_ms: backoff_ms,
        last_error_at: now,
        last_error: inspect(error)
      })

    new_state = put_in(state.sources[{device_id, source_name}], source_state)
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:persistence, queue_depth, last_flush_at}, state) do
    new_persistence =
      state.persistence
      |> Map.put(:queue_depth, queue_depth)
      |> Map.put(:last_flush_at, last_flush_at || state.persistence.last_flush_at)

    new_state = %{state | persistence: new_persistence}
    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_cast({:retention, result, at, message}, state) do
    new_state = %{state | retention: %{status: result, at: at, message: message}}
    broadcast(new_state)
    {:noreply, new_state}
  end

  defp seed_sources do
    for {device, source} <- Topology.enabled_sources(), into: %{} do
      {{device.id, source.name},
       %{
         device_id: device.id,
         source: source.name,
         last_ok_at: nil,
         consecutive_failures: 0,
         backoff_ms: 0,
         last_error_at: nil,
         last_error: nil
       }}
    end
  end

  defp broadcast(state) do
    if Process.whereis(NerveCenter.PubSub) do
      Phoenix.PubSub.broadcast(
        NerveCenter.PubSub,
        Topology.app_health_topic(),
        %AppHealthUpdated{health: state, emitted_at: DateTime.utc_now()}
      )
    end
  end
end
