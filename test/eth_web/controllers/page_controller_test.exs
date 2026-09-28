defmodule EthWeb.PageControllerTest do
  use EthWeb.ConnCase

  test "GET / muestra la página base en español", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~r/<html[^>]* lang="es"/
    assert html =~ "Cazador de trades"
    assert html =~ "Tema oscuro"
  end

  test "GET / envía una CSP que autoriza el script de tema por hash", %{conn: conn} do
    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")
    hash = :sha256 |> :crypto.hash(EthWeb.CSP.theme_script()) |> Base.encode64()

    assert csp =~ "script-src 'self' 'sha256-#{hash}'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
    assert html_response(conn, 200) =~ EthWeb.CSP.theme_script()
  end
end
