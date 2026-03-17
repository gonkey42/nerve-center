defmodule NerveCenter.Sources.HAL9000.PlexSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Sources.Support

  @impl true
  def required_env, do: ["PLEX_TOKEN"]

  @impl true
  def normal_interval_ms, do: 30_000

  @impl true
  def stale_after_ms, do: 90_000

  @impl true
  def probe(context) do
    poll(context)
  end

  @impl true
  def poll(context) do
    token = URI.encode_www_form(System.fetch_env!("PLEX_TOKEN"))
    Support.request_json("#{context.device.plex_base_url}/status/sessions?X-Plex-Token=#{token}")
  end

  @impl true
  def normalize(raw, _context) do
    media_container = raw["MediaContainer"] || %{}
    active_streams = Support.first_present(media_container, [:size], 0)

    {:ok,
     %{
       observed_at: DateTime.utc_now(),
       metrics: [%{metric: :plex_active_streams_count, value: active_streams}],
       data: %{active_streams: active_streams}
     }}
  end
end
