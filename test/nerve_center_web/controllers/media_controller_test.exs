defmodule NerveCenterWeb.MediaControllerTest do
  use NerveCenterWeb.ConnCase, async: false

  alias NerveCenter.Runtime.ImageCache

  test "serves cached Frigate preview with cache headers", %{conn: conn} do
    :ok = ImageCache.put("livingroom", <<255, 216, 255, 217>>, "image/jpeg")

    conn = get(conn, "/media/frigate/livingroom/latest.jpg")

    assert conn.status == 200
    assert conn.resp_body == <<255, 216, 255, 217>>
    assert get_resp_header(conn, "cache-control") == ["max-age=5, stale-while-revalidate=30"]
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"")
  end

  test "returns 304 when etag matches", %{conn: conn} do
    :ok = ImageCache.put("livingroom", <<255, 216, 255, 217>>, "image/jpeg")
    {:ok, entry} = ImageCache.get("livingroom")

    conn =
      conn
      |> put_req_header("if-none-match", ~s("#{entry.etag}"))
      |> get("/media/frigate/livingroom/latest.jpg")

    assert conn.status == 304
    assert conn.resp_body == ""
  end
end
