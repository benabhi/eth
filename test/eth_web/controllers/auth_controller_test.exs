defmodule EthWeb.AuthControllerTest do
  use EthWeb.ConnCase, async: false

  alias Eth.Characters
  alias Eth.Sso.Jwt
  alias Eth.SsoFixture, as: F

  @moduletag :capture_log

  setup_all do
    {:ok, keys: F.keys()}
  end

  setup do
    Jwt.clear_cache()
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    # La sesión del personaje no pide nada a ESI en estos tests.
    Req.Test.stub(Eth.Esi.Client, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    start_supervised!(Eth.Characters.Supervisor)
    :ok
  end

  test "la solicitud redirige al SSO con los 13 scopes y un state", %{conn: conn} do
    conn = get(conn, ~p"/auth/eve")
    location = redirected_to(conn, 302)
    uri = URI.parse(location)
    query = URI.decode_query(uri.query)

    assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
             "https://login.eveonline.com/v2/oauth/authorize"

    assert query["client_id"] == "test-client-id"
    assert query["redirect_uri"] == "http://localhost:4000/auth/eve/callback"
    assert query["response_type"] == "code"
    assert length(String.split(query["scope"], " ")) == 13
    assert query["state"] != nil
  end

  test "el callback verifica el login, guarda el personaje y abre la sesión", %{
    conn: conn,
    keys: keys
  } do
    F.stub(keys, F.token_body(F.access_token(keys), "refresh-secreto"))

    conn = get(conn, ~p"/auth/eve")

    state =
      conn
      |> redirected_to(302)
      |> URI.parse()
      |> Map.get(:query)
      |> URI.decode_query()
      |> Map.get("state")

    conn = conn |> recycle() |> get(~p"/auth/eve/callback?code=abc&state=#{state}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :character_id) == F.character_id()

    character = Characters.get(F.character_id())
    assert character.name == "Hernan Test"
    assert character.refresh_token == "refresh-secreto"

    # En la base el refresh token está cifrado (RNF-4.2).
    %{rows: [[raw]]} =
      Eth.Repo.query!("select refresh_token from characters where id = $1", [F.character_id()])

    refute raw =~ "refresh-secreto"
  end

  test "sin state válido el callback falla", %{conn: conn, keys: keys} do
    F.stub(keys, F.token_body(F.access_token(keys)))
    conn = get(conn, ~p"/auth/eve/callback?code=abc&state=inventado")

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "No se pudo iniciar sesión"
    assert Characters.get(F.character_id()) == nil
  end

  test "cerrar sesión quita el personaje activo", %{conn: conn} do
    conn = conn |> init_test_session(character_id: 123) |> post(~p"/auth/logout")
    assert get_session(conn, :character_id) == nil
  end
end
