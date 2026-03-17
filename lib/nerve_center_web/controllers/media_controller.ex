defmodule NerveCenterWeb.MediaController do
  use NerveCenterWeb, :controller

  alias NerveCenter.Runtime.ImageCache

  @cache_control "max-age=5, stale-while-revalidate=30"

  def show_frigate_latest(conn, %{"camera" => camera}) do
    case ImageCache.get(camera) do
      {:ok, entry} ->
        etag = etag_value(entry.etag)

        conn =
          conn
          |> put_resp_header("cache-control", @cache_control)
          |> put_resp_header("etag", etag)
          |> put_resp_content_type(entry.content_type, nil)

        if matches_etag?(conn, etag) do
          send_resp(conn, :not_modified, "")
        else
          send_resp(conn, :ok, entry.jpeg_binary)
        end

      :error ->
        send_resp(conn, :not_found, "preview not cached")
    end
  end

  defp etag_value(etag), do: ~s("#{etag}")

  defp matches_etag?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.any?(fn value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.member?(etag)
    end)
  end
end
