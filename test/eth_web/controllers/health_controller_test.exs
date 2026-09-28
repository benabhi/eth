defmodule EthWeb.HealthControllerTest do
  use EthWeb.ConnCase, async: true

  test "GET /health responde ok", %{conn: conn} do
    assert %{"status" => "ok"} = conn |> get(~p"/health") |> json_response(200)
  end

  test "GET /ready verifica la base de datos", %{conn: conn} do
    assert %{"status" => "ok", "checks" => %{"database" => "ok"}} =
             conn |> get(~p"/ready") |> json_response(200)
  end
end
