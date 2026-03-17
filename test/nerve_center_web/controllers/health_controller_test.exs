defmodule NerveCenterWeb.HealthControllerTest do
  use NerveCenterWeb.ConnCase, async: true

  test "GET /healthz returns ok json", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200)["status"] == "ok"

    assert %{
             "repo" => true,
             "persistence_writer" => true,
             "migration" => true
           } = json_response(conn, 200)["checks"]
  end
end
