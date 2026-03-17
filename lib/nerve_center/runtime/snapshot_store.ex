defmodule NerveCenter.Runtime.SnapshotStore do
  @moduledoc false

  use GenServer

  alias NerveCenter.Snapshot.DeviceSnapshot
  alias NerveCenter.Topology

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def snapshot(device_id) do
    case :ets.lookup(@table, device_id) do
      [{^device_id, snapshot}] -> snapshot
      [] -> nil
    end
  end

  def put(%DeviceSnapshot{device_id: device_id} = snapshot) do
    :ets.insert(@table, {device_id, snapshot})
    :ok
  end

  def all_snapshots do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_device_id, snapshot} -> snapshot end)
  end

  @impl true
  def init(_state) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_unknown_snapshots()
    {:ok, %{}}
  end

  defp seed_unknown_snapshots do
    Enum.each(Topology.all_devices(), fn device ->
      :ets.insert_new(@table, {device.id, unknown_snapshot(device)})
    end)
  end

  defp unknown_snapshot(device) do
    %DeviceSnapshot{
      device_id: device.id,
      label: device.label,
      status: :unknown,
      updated_at: nil,
      offline_expected: device.offline_expected,
      metrics: %{},
      sources: %{}
    }
  end
end
