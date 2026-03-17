defmodule NerveCenter.Sources.HAL9000.LocalMetricsSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  @impl true
  def required_env, do: []

  @impl true
  def normal_interval_ms, do: 10_000

  @impl true
  def stale_after_ms, do: 30_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       method: "os_mon + sysctl + netstat",
       device: context.device.label
     }}
  end

  @impl true
  def poll(_context) do
    :ok = Application.ensure_all_started(:os_mon) |> elem(0)

    {:ok,
     %{
       cpu: :cpu_sup.util(),
       memory: :memsup.get_system_memory_data(),
       disks: :disksup.get_disk_data(),
       network: parse_network_totals(),
       boot_time_sec: parse_boot_time_sec()
     }}
  rescue
    error -> {:error, {:local_metrics, Exception.message(error)}}
  end

  @impl true
  def normalize(raw, context) do
    {disk_total_bytes, disk_used_bytes} = select_disk(raw.disks)
    {rx_rate, tx_rate, private} = network_rates(raw.network, context.private)
    memory_total = Keyword.fetch!(raw.memory, :total_memory)
    memory_used = memory_total - Keyword.get(raw.memory, :available_memory, 0)
    uptime_seconds = max(System.os_time(:second) - raw.boot_time_sec, 0)

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       private: private,
       metrics: [
         %{metric: :cpu_util_ratio, value: raw.cpu / 100},
         %{metric: :memory_used_bytes, value: memory_used},
         %{metric: :memory_total_bytes, value: memory_total},
         %{metric: :disk_used_bytes, value: disk_used_bytes},
         %{metric: :disk_total_bytes, value: disk_total_bytes},
         %{metric: :network_rx_bytes_per_sec, value: rx_rate},
         %{metric: :network_tx_bytes_per_sec, value: tx_rate},
         %{metric: :uptime_seconds, value: uptime_seconds}
       ],
       data: %{
         cpu_percent: raw.cpu,
         memory_used_bytes: memory_used,
         memory_total_bytes: memory_total,
         disk_used_bytes: disk_used_bytes,
         disk_total_bytes: disk_total_bytes,
         network_rx_bytes_per_sec: rx_rate,
         network_tx_bytes_per_sec: tx_rate,
         uptime_seconds: uptime_seconds
       }
     }}
  end

  defp select_disk(disks) do
    disk =
      Enum.find(disks, fn {path, _total_kb, _used_percent} ->
        List.to_string(path) == "/System/Volumes/Data"
      end) ||
        Enum.find(disks, fn {path, _total_kb, _used_percent} -> List.to_string(path) == "/" end) ||
        hd(disks)

    {_, total_kb, used_percent} = disk
    total_bytes = total_kb * 1024
    used_bytes = round(total_bytes * (used_percent / 100))
    {total_bytes, used_bytes}
  end

  defp parse_network_totals do
    {output, 0} = System.cmd("netstat", ["-ibn"], stderr_to_stdout: true)

    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.reduce(%{rx: 0, tx: 0}, fn line, acc ->
      case String.split(line, ~r/\s+/, trim: true) do
        [name, _mtu, network, _address, _ipkts, _ierrs, ibytes, _opkts, _oerrs, obytes | _rest] ->
          if String.contains?(network, "<Link#") and name != "lo0" and
               not String.ends_with?(name, "*") do
            %{rx: acc.rx + String.to_integer(ibytes), tx: acc.tx + String.to_integer(obytes)}
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp parse_boot_time_sec do
    {output, 0} = System.cmd("sysctl", ["kern.boottime"], stderr_to_stdout: true)

    case Regex.run(~r/sec = (\d+)/, output, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> raise "unable to parse kern.boottime"
    end
  end

  defp network_rates(current_totals, %{
         network: %{rx: last_rx, tx: last_tx},
         sampled_at: sampled_at
       }) do
    elapsed_seconds = max(System.monotonic_time(:millisecond) - sampled_at, 1) / 1_000
    rx_rate = max((current_totals.rx - last_rx) / elapsed_seconds, 0.0)
    tx_rate = max((current_totals.tx - last_tx) / elapsed_seconds, 0.0)

    {rx_rate, tx_rate,
     %{network: current_totals, sampled_at: System.monotonic_time(:millisecond)}}
  end

  defp network_rates(current_totals, _private) do
    {0.0, 0.0, %{network: current_totals, sampled_at: System.monotonic_time(:millisecond)}}
  end
end
