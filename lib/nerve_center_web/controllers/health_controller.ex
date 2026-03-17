defmodule NerveCenterWeb.HealthController do
  use NerveCenterWeb, :controller

  alias NerveCenter.Runtime.Health

  def show(conn, _params) do
    checks = Health.checks()
    status = if Enum.all?(Map.values(checks)), do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(%{
      status: if(status == :ok, do: "ok", else: "error"),
      checks: checks
    })
  end
end
