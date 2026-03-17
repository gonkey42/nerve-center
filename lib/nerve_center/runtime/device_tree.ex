defmodule NerveCenter.Runtime.DeviceTree do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    device = Keyword.fetch!(opts, :device)
    Supervisor.start_link(__MODULE__, device, name: {:global, {:device_tree, device.id}})
  end

  @impl true
  def init(device) do
    hub_child = {device.hub_module, [device: device]}

    source_children =
      Enum.map(Enum.filter(device.sources, & &1.enabled), fn source ->
        source.module.child_spec(device: device, source: source)
      end)

    Supervisor.init([hub_child | source_children], strategy: :rest_for_one)
  end
end
