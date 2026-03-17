defmodule NerveCenter.Sources.HAL9000.LaunchdSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  @impl true
  def required_env, do: []

  @impl true
  def normal_interval_ms, do: 15_000

  @impl true
  def stale_after_ms, do: 45_000

  @impl true
  def probe(context) do
    {:ok, %{labels: context.device.launchd_labels}}
  end

  @impl true
  def poll(context) do
    services =
      Enum.map(context.device.launchd_labels, fn label ->
        {output, _exit_status} = System.cmd("launchctl", ["list", label], stderr_to_stdout: true)
        parse_service(label, output)
      end)

    {:ok, %{services: services}}
  rescue
    error -> {:error, {:launchd, Exception.message(error)}}
  end

  @impl true
  def normalize(raw, _context) do
    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [],
       data: %{services: raw.services}
     }}
  end

  defp parse_service(label, output) do
    pid =
      case Regex.run(~r/"PID"\s*=\s*(\d+);/, output, capture: :all_but_first) do
        [value] -> String.to_integer(value)
        _ -> nil
      end

    last_exit_status =
      case Regex.run(~r/"LastExitStatus"\s*=\s*(\d+);/, output, capture: :all_but_first) do
        [value] -> String.to_integer(value)
        _ -> nil
      end

    %{
      label: label,
      running: not is_nil(pid),
      pid: pid,
      last_exit_status: last_exit_status
    }
  end
end
