defmodule NerveCenter.Sources.Rosie.FrigateSource do
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
    {:ok,
     %{
       api_base_url: "#{context.device.frigate_base_url}/api",
       configured_cameras: context.device.frigate_preview_cameras
     }}
  end

  @impl true
  def poll(context) do
    Support.request_json("#{context.device.frigate_base_url}/api/stats")
  end

  @impl true
  def normalize(raw, _context) do
    detection_fps = raw |> Support.first_present([:detection_fps], 0) |> Support.to_float()
    process_fps = raw |> camera_stats() |> Enum.reduce(0.0, &(&1.process_fps + &2))

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [
         %{metric: :frigate_detection_fps, value: detection_fps},
         %{metric: :frigate_process_fps, value: process_fps}
       ],
       data: %{
         detection_fps: detection_fps,
         process_fps: process_fps,
         version: Support.first_present(raw, [{:service, :version}], nil),
         service_uptime_seconds: Support.first_present(raw, [{:service, :uptime}], nil),
         cameras: camera_stats(raw)
       }
     }}
  end

  defp camera_stats(raw) do
    raw
    |> Support.first_present([:cameras], %{})
    |> Enum.map(fn {camera_name, stats} ->
      %{
        camera_name: camera_name,
        detection_fps: stats |> Support.first_present([:detection_fps], 0) |> Support.to_float(),
        process_fps: stats |> Support.first_present([:process_fps], 0) |> Support.to_float(),
        camera_fps: stats |> Support.first_present([:camera_fps], 0) |> Support.to_float(),
        detection_enabled: Support.first_present(stats, [:detection_enabled], false)
      }
    end)
  end
end
