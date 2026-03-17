defmodule NerveCenter.Runtime.DeviceTreeTest do
  use ExUnit.Case, async: false

  alias NerveCenter.Runtime.DeviceTree

  defmodule FakeHub do
    use GenServer

    def start_link(opts) do
      device = Keyword.fetch!(opts, :device)
      name = {:via, Registry, {NerveCenter.Runtime.DeviceRegistry, device.id}}
      GenServer.start_link(__MODULE__, device, name: name)
    end

    @impl true
    def init(device), do: {:ok, %{device: device}}

    @impl true
    def handle_cast(_message, state), do: {:noreply, state}
  end

  defmodule StaticSource do
    use NerveCenter.Runtime.PollingSource

    @impl true
    def required_env, do: []

    @impl true
    def normal_interval_ms, do: 60_000

    @impl true
    def stale_after_ms, do: 180_000

    @impl true
    def probe(_context), do: {:ok, %{mode: "test"}}

    @impl true
    def poll(%{source: %{name: source_name, test_pid: test_pid}}) do
      send(test_pid, {:polled, source_name, self()})
      {:ok, %{source_name: source_name}}
    end

    @impl true
    def normalize(raw, _context) do
      {:ok,
       %{
         observed_at: DateTime.utc_now(),
         data: %{source_name: raw.source_name}
       }}
    end
  end

  test "restarts only the crashed source process" do
    device = test_device(self())
    tree = start_supervised!({DeviceTree, device: device})

    assert_receive {:polled, :first, first_pid}, 1_000
    assert_receive {:polled, :second, second_pid}, 1_000
    assert Process.alive?(first_pid)
    assert Process.alive?(second_pid)

    monitor_ref = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)

    assert_receive {:DOWN, ^monitor_ref, :process, ^first_pid, :killed}, 1_000
    assert_receive {:polled, :first, restarted_first_pid}, 1_000

    refute restarted_first_pid == first_pid
    assert Process.alive?(restarted_first_pid)
    assert Process.alive?(second_pid)

    assert child_pid(tree, {StaticSource, device.id, :second}) == second_pid
  end

  defp test_device(test_pid) do
    id = :"device_tree_test_#{System.unique_integer([:positive])}"

    %{
      id: id,
      label: "Device Tree Test",
      offline_expected: false,
      hub_module: FakeHub,
      sources: [
        %{
          name: :first,
          module: StaticSource,
          enabled: true,
          interval_ms: 60_000,
          test_pid: test_pid
        },
        %{
          name: :second,
          module: StaticSource,
          enabled: true,
          interval_ms: 60_000,
          test_pid: test_pid
        }
      ]
    }
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end
end
