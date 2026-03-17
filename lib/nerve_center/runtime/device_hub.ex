defmodule NerveCenter.Runtime.DeviceHub do
  @moduledoc false

  use GenServer

  alias NerveCenter.Messages.DeviceSnapshotUpdated
  alias NerveCenter.Runtime.SnapshotStore
  alias NerveCenter.Topology

  def start_link(opts) do
    device = Keyword.fetch!(opts, :device)
    name = {:via, Registry, {NerveCenter.Runtime.DeviceRegistry, device.id}}
    GenServer.start_link(__MODULE__, %{device: device}, name: name)
  end

  @impl true
  def init(%{device: device} = state) do
    {:ok, Map.put(state, :snapshot, SnapshotStore.snapshot(device.id))}
  end

  @impl true
  def handle_cast({:source_update, source_name, source_snapshot}, state) do
    snapshot = merge_source_snapshot(state.device, state.snapshot, source_name, source_snapshot)
    SnapshotStore.put(snapshot)

    Phoenix.PubSub.broadcast(
      NerveCenter.PubSub,
      Topology.device_topic(state.device.id),
      %DeviceSnapshotUpdated{
        device_id: state.device.id,
        snapshot: snapshot,
        emitted_at: DateTime.utc_now()
      }
    )

    {:noreply, %{state | snapshot: snapshot}}
  end

  defp merge_source_snapshot(device, snapshot, source_name, source_snapshot) do
    sources = Map.put(snapshot.sources, source_name, source_snapshot)

    metrics =
      sources
      |> Enum.flat_map(fn {_name, source_snapshot} -> Map.to_list(source_snapshot.metrics) end)
      |> Map.new()

    %{
      snapshot
      | sources: sources,
        metrics: metrics,
        status: status_for(sources),
        updated_at: DateTime.utc_now()
    }
    |> Map.put(:offline_expected, device.offline_expected)
  end

  defp status_for(sources) when map_size(sources) == 0, do: :unknown

  defp status_for(sources) do
    source_states = Map.values(sources)

    cond do
      Enum.all?(source_states, &(not &1.ever_ok?)) ->
        :unknown

      Enum.all?(source_states, &(&1.status == :ok)) ->
        :ok

      Enum.all?(source_states, &(&1.status == :error)) ->
        :offline

      true ->
        :degraded
    end
  end
end
