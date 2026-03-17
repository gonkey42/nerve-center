defmodule NerveCenterWeb.MetricsController do
  use NerveCenterWeb, :controller

  alias NerveCenter.Metrics.Exporter

  def show(conn, _params) do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, Exporter.render())
  end
end
