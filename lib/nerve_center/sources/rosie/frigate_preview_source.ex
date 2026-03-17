defmodule NerveCenter.Sources.Rosie.FrigatePreviewSource do
  @moduledoc false

  use NerveCenter.Runtime.PollingSource

  alias NerveCenter.Runtime.ImageCache
  alias NerveCenter.Sources.Support

  require Logger

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
       cache: "NerveCenter.Runtime.ImageCache",
       cameras: context.device.frigate_preview_cameras,
       media_path_template: "/media/frigate/:camera/latest.jpg"
     }}
  end

  @impl true
  def poll(context) do
    Enum.reduce_while(context.device.frigate_preview_cameras, {:ok, []}, fn camera, {:ok, acc} ->
      snapshot_url = "#{context.device.frigate_base_url}/api/#{camera}/latest.jpg"

      with {:ok, response} <-
             Support.request_binary(snapshot_url, headers: [{"accept", "image/jpeg"}]),
           :ok <- ensure_jpeg(camera, response.content_type),
           :ok <- cache_preview(camera, response),
           {:ok, entry} <- ImageCache.get(camera) do
        {:cont,
         {:ok,
          [
            %{
              camera_name: camera,
              cache_path: "/media/frigate/#{camera}/latest.jpg",
              etag: entry.etag,
              content_type: entry.content_type,
              fetched_at: entry.fetched_at,
              size_bytes: byte_size(response.body)
            }
            | acc
          ]}}
      else
        {:error, {:too_large, size_bytes}} ->
          Logger.warning(
            "rejecting Frigate preview for #{camera}: #{size_bytes} bytes exceeds ImageCache limit"
          )

          {:halt, {:error, {:too_large, camera, size_bytes}}}

        {:error, reason} ->
          Logger.warning("Frigate preview fetch failed for #{camera}: #{inspect(reason)}")
          {:halt, {:error, {:camera_fetch_failed, camera, reason}}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  @impl true
  def normalize(entries, _context) do
    observed_at =
      case entries do
        [] -> DateTime.utc_now()
        _ -> Enum.max_by(entries, &DateTime.to_unix(&1.fetched_at, :microsecond)).fetched_at
      end

    {:ok,
     %{
       observed_at: observed_at,
       data: %{entries: entries}
     }}
  end

  defp ensure_jpeg(_camera, "image/jpeg"), do: :ok
  defp ensure_jpeg(_camera, "image/jpeg; charset=binary"), do: :ok

  defp ensure_jpeg(camera, content_type) do
    {:error, {:unexpected_content_type, camera, content_type}}
  end

  defp cache_preview(camera, %{body: body, content_type: content_type}) do
    case ImageCache.put(camera, body, content_type) do
      :ok -> :ok
      {:error, :too_large} -> {:error, {:too_large, byte_size(body)}}
    end
  end
end
