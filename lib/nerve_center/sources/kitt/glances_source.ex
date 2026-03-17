defmodule NerveCenter.Sources.Kitt.GlancesSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: []

  @impl true
  def normal_interval_ms, do: 30_000

  @impl true
  def stale_after_ms, do: 90_000

  @impl true
  def probe(context) do
    Support.request_json("#{context.device.glances_base_url}/api/4/cpu")
  end

  @impl true
  def poll(context) do
    base = context.device.glances_base_url

    with {:ok, cpu} <- Support.request_json("#{base}/api/4/cpu"),
         {:ok, mem} <- Support.request_json("#{base}/api/4/mem"),
         {:ok, fs} <- Support.request_json("#{base}/api/4/fs"),
         {:ok, network} <- Support.request_json("#{base}/api/4/network"),
         {:ok, uptime} <- Support.request_json("#{base}/api/4/uptime") do
      {:ok, %{cpu: cpu, mem: mem, fs: fs, network: network, uptime: uptime}}
    end
  end

  @impl true
  def normalize(raw, _context) do
    cpu_ratio =
      raw.cpu
      |> Support.first_present([:total, {:cpu_number, :total}], 0)
      |> Support.ratio_from_percent()

    memory_total = raw.mem |> Support.first_present([:total], 0) |> Support.to_integer()

    memory_used =
      raw.mem
      |> Support.first_present(
        [:used],
        memory_total - Support.first_present(raw.mem, [:free, :available], 0)
      )
      |> Support.to_integer()

    {disk_total, disk_used} = parse_fs(raw.fs)
    {network_rx, network_tx} = parse_network(raw.network)
    uptime_seconds = parse_uptime(raw.uptime)

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [
         %{metric: :cpu_util_ratio, value: cpu_ratio},
         %{metric: :memory_used_bytes, value: memory_used},
         %{metric: :memory_total_bytes, value: memory_total},
         %{metric: :disk_used_bytes, value: disk_used},
         %{metric: :disk_total_bytes, value: disk_total},
         %{metric: :network_rx_bytes_per_sec, value: network_rx},
         %{metric: :network_tx_bytes_per_sec, value: network_tx},
         %{metric: :uptime_seconds, value: uptime_seconds}
       ],
       data: %{
         cpu_util_ratio: cpu_ratio,
         memory_used_bytes: memory_used,
         memory_total_bytes: memory_total,
         disk_used_bytes: disk_used,
         disk_total_bytes: disk_total,
         network_rx_bytes_per_sec: network_rx,
         network_tx_bytes_per_sec: network_tx,
         uptime_seconds: uptime_seconds
       }
     }}
  end

  defp parse_fs(items) when is_list(items) do
    root =
      Enum.find(items, fn item ->
        Support.first_present(item, [:mnt_point, :mountpoint, :fsname], "") == "/"
      end) || hd(items)

    total = root |> Support.first_present([:size, :total], 0) |> Support.to_integer()

    used =
      root
      |> Support.first_present(
        [:used, :used_bytes],
        round(total * Support.first_present(root, [:percent], 0) / 100)
      )
      |> Support.to_integer()

    {total, used}
  end

  defp parse_network(items) when is_list(items) do
    usable_items =
      Enum.reject(items, fn item ->
        interface = Support.first_present(item, [:interface_name, :name], "")
        interface == "lo" or interface == "lo0"
      end)

    rx = Support.sum_fields(usable_items, [:rx, :rx_bytes_per_sec, :bytes_recv_rate_per_sec])
    tx = Support.sum_fields(usable_items, [:tx, :tx_bytes_per_sec, :bytes_sent_rate_per_sec])
    {rx, tx}
  end

  defp parse_uptime(%{"uptime" => value}), do: Support.parse_uptime_seconds(value)
  defp parse_uptime(%{uptime: value}), do: Support.parse_uptime_seconds(value)
  defp parse_uptime(value), do: Support.parse_uptime_seconds(value)
end
