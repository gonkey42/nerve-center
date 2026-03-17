defmodule NerveCenter.Sources.Rosie.ImmichSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: ["IMMICH_API_KEY"]

  @impl true
  def normal_interval_ms, do: 60_000

  @impl true
  def stale_after_ms, do: 180_000

  @impl true
  def probe(context) do
    {:ok,
     %{
       api_base_url: "#{context.device.immich_base_url}/api",
       auth: "x-api-key"
     }}
  end

  @impl true
  def poll(context) do
    Support.request_json("#{context.device.immich_base_url}/api/server/statistics",
      headers: [{"x-api-key", System.fetch_env!("IMMICH_API_KEY")}]
    )
  end

  @impl true
  def normalize(raw, _context) do
    photos = raw |> Support.first_present([:photos], 0) |> Support.to_integer()
    videos = raw |> Support.first_present([:videos], 0) |> Support.to_integer()
    storage_used = raw |> Support.first_present([:usage], 0) |> Support.to_integer()
    assets = photos + videos

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [
         %{metric: :immich_assets_count, value: assets},
         %{metric: :immich_images_count, value: photos},
         %{metric: :immich_videos_count, value: videos},
         %{metric: :immich_storage_used_bytes, value: storage_used}
       ],
       data: %{
         assets_count: assets,
         images_count: photos,
         videos_count: videos,
         storage_used_bytes: storage_used,
         usage_by_user:
           Enum.map(raw["usageByUser"] || raw[:usageByUser] || [], fn item ->
             %{
               user_name: Support.first_present(item, [:userName], nil),
               photos: Support.first_present(item, [:photos], 0),
               videos: Support.first_present(item, [:videos], 0),
               usage_bytes: Support.first_present(item, [:usage], 0)
             }
           end)
       }
     }}
  end
end
