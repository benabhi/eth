defmodule Eth.SsoTest do
  use ExUnit.Case, async: false

  alias Eth.Sso
  alias Eth.Sso.{Jwt, Token}
  alias Eth.SsoFixture, as: F

  setup_all do
    {:ok, keys: F.keys()}
  end

  setup do
    Jwt.clear_cache()
    :ok
  end

  describe "verificación del JWT" do
    test "acepta RS256 y ES256 y extrae el personaje", %{keys: keys} do
      F.stub(keys, %{})

      for alg <- [:rs256, :es256] do
        assert {:ok, claims} = Jwt.verify(F.access_token(keys, alg))
        assert claims.character_id == F.character_id()
        assert claims.name == "Hernan Test"
        assert claims.owner_hash == "owner-hash-1"
        assert "esi-ui.open_window.v1" in claims.scopes
      end
    end

    test "rechaza audiencia, emisor, vencimiento o firma inválidos", %{keys: keys} do
      F.stub(keys, %{})

      assert {:error, :invalid_audience} =
               Jwt.verify(F.access_token(keys, :rs256, %{"aud" => ["otra-app", "EVE Online"]}))

      assert {:error, :invalid_audience} =
               Jwt.verify(F.access_token(keys, :rs256, %{"aud" => "test-client-id"}))

      assert {:error, :invalid_issuer} =
               Jwt.verify(F.access_token(keys, :rs256, %{"iss" => "https://evil.example"}))

      assert {:error, :expired} =
               Jwt.verify(
                 F.access_token(keys, :rs256, %{"exp" => DateTime.to_unix(DateTime.utc_now()) - 1})
               )

      # Firmado con una clave que no es la publicada para ese kid.
      other = %{rs256: {"JWT-Signature-Key", JOSE.JWK.generate_key({:rsa, 2048})}}
      assert {:error, :invalid_signature} = Jwt.verify(F.access_token(other))
    end

    test "un kid desconocido vuelve a pedir el JWKS (rotación de claves)", %{keys: keys} do
      F.stub(keys, %{})
      assert {:ok, _} = Jwt.verify(F.access_token(keys))

      rotated = %{rs256: {"nueva-clave", JOSE.JWK.generate_key({:rsa, 2048})}}
      F.stub(rotated, %{})
      assert {:ok, _} = Jwt.verify(F.access_token(rotated))
    end
  end

  describe "tokens" do
    test "login: intercambio del código y verificación", %{keys: keys} do
      F.stub(keys, F.token_body(F.access_token(keys), "refresh-rotado"))

      assert {:ok, login} = Sso.login("code-123")
      assert login.character_id == F.character_id()
      assert login.refresh_token == "refresh-rotado"
      assert DateTime.diff(login.expires_at, DateTime.utc_now()) in 1190..1199
    end

    test "invalid_grant se distingue de otros errores", %{keys: keys} do
      F.stub(keys, {400, %{"error" => "invalid_grant"}})
      assert Token.refresh("viejo") == {:error, :invalid_grant}

      F.stub(keys, {503, %{"error" => "down"}})
      assert Token.refresh("viejo") == {:error, {:http, 503}}
    end
  end

  test "configuración y lista blanca" do
    assert Sso.configured?()
    assert Sso.allowed?(F.character_id())
    assert Sso.missing_scopes(["publicData"]) |> length() == 11
  end
end
