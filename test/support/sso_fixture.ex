defmodule Eth.SsoFixture do
  @moduledoc """
  SSO de EVE simulado para tests sin red: genera claves RS256 y ES256 como las del JWKS
  real, firma access tokens y responde los endpoints de token, JWKS y revocación con
  `Req.Test`.
  """

  import Plug.Conn

  @character_id 2_112_345_678

  def character_id, do: @character_id

  @doc "Claves de prueba (RS256 con kid como el del SSO real y ES256)."
  def keys do
    %{
      rs256: {"JWT-Signature-Key", JOSE.JWK.generate_key({:rsa, 2048})},
      es256: {"es-key", JOSE.JWK.generate_key({:ec, "P-256"})}
    }
  end

  @doc "Cuerpo JWKS público con las claves dadas."
  def jwks(keys) do
    %{
      "keys" =>
        for {alg, {kid, jwk}} <- keys do
          {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
          Map.merge(public, %{"kid" => kid, "alg" => alg |> Atom.to_string() |> String.upcase()})
        end
    }
  end

  @doc "Access token firmado. `overrides` reemplaza claims."
  def access_token(keys, alg \\ :rs256, overrides \\ %{}) do
    {kid, jwk} = Map.fetch!(keys, alg)

    claims =
      Map.merge(
        %{
          "iss" => "https://login.eveonline.com",
          "aud" => ["test-client-id", "EVE Online"],
          "sub" => "CHARACTER:EVE:#{@character_id}",
          "name" => "Hernan Test",
          "owner" => "owner-hash-1",
          "scp" => Eth.Sso.scopes(),
          "exp" => DateTime.to_unix(DateTime.utc_now()) + 1199
        },
        overrides
      )

    header = %{"alg" => alg |> Atom.to_string() |> String.upcase(), "kid" => kid, "typ" => "JWT"}
    {_, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  @doc """
  Stub de los endpoints del SSO. `token_response` es el cuerpo (o `{status, cuerpo}`)
  que devuelve el endpoint de token.
  """
  def stub(keys, token_response) do
    Req.Test.stub(Eth.Sso, fn conn ->
      case conn.request_path do
        "/oauth/jwks" ->
          json(conn, 200, jwks(keys))

        "/v2/oauth/token" ->
          token_reply(conn, token_response)

        "/v2/oauth/revoke" ->
          send_resp(conn, 200, "")
      end
    end)
  end

  @doc "Respuesta de tokens del SSO."
  def token_body(access_token, refresh_token \\ "refresh-1") do
    %{
      "access_token" => access_token,
      "expires_in" => 1199,
      "token_type" => "Bearer",
      "refresh_token" => refresh_token
    }
  end

  defp token_reply(conn, {status, body}), do: json(conn, status, body)
  defp token_reply(conn, body), do: json(conn, 200, body)

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
