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
    {:ok, %{labels: Enum.map(context.device.launchd_labels, &service_label/1)}}
  end

  @impl true
  def poll(context) do
    services =
      Enum.map(context.device.launchd_labels, fn service ->
        label = service_label(service)
        {output, _exit_status} = System.cmd("launchctl", ["list", label], stderr_to_stdout: true)

        service
        |> parse_service(output)
        |> Map.put(:display_name, service_display_name(service))
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

  def control_service(device, label, action) when action in [:start, :stop, :restart] do
    with :ok <- ensure_configured_label(device, label) do
      run_launchctl(label, action)
    end
  end

  defp service_label(%{label: label}), do: label
  defp service_label(label), do: label

  defp service_display_name(%{display_name: display_name}), do: display_name
  defp service_display_name(label), do: label

  defp parse_service(service, output) do
    label = service_label(service)

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

  defp ensure_configured_label(device, label) do
    if label in Enum.map(device.launchd_labels, &service_label/1) do
      :ok
    else
      {:error, {:unknown_launchd_label, label}}
    end
  end

  defp run_launchctl(label, action) do
    args =
      case action do
        :start -> ["kickstart", service_target(label)]
        :stop -> ["bootout", service_target(label)]
        :restart -> ["kickstart", "-k", service_target(label)]
      end

    case System.cmd("launchctl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:launchctl, status, String.trim(output)}}
    end
  rescue
    error -> {:error, {:launchctl, Exception.message(error)}}
  end

  defp service_target(label), do: "gui/#{System.get_env("UID") || uid()}/#{label}"

  defp uid do
    {output, 0} = System.cmd("id", ["-u"], stderr_to_stdout: true)
    String.trim(output)
  rescue
    _error -> "501"
  end
end
