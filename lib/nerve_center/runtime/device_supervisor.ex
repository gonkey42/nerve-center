defmodule NerveCenter.Runtime.DeviceSupervisor do
  @moduledoc false

  use Supervisor

  @devices NerveCenter.Topology.enabled_devices()

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = Enum.map(@devices, &device_tree_child/1)
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp device_tree_child(device) do
    Supervisor.child_spec({NerveCenter.Runtime.DeviceTree, device: device},
      id: {:device_tree, device.id}
    )
  end
end
