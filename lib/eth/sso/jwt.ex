defmodule Eth.Sso.Jwt do
  @moduledoc """
  Verificación del access token JWT de EVE SSO (RF-5.1, RNF-4.3).

  - Firma: la clave se elige por `kid` en el JWKS del SSO, que hoy publica una clave
    RS256 y otra ES256 (verificado 2026-09-29). El JWKS se cachea y se vuelve a pedir si
    aparece un `kid` desconocido (rotación de claves).
  - Claims: `iss` de EVE, `aud` con el `client_id` **y** "EVE Online", `exp` vigente y
    `sub` con la forma `CHARACTER:EVE:<id>`.

  Implementa: RF-5.1, RNF-4.3.
  """

  alias Eth.{Clock, Sso}

  @cache {__MODULE__, :jwks}
  @algorithms ["RS256", "ES256"]

  @type claims :: %{
          character_id: pos_integer(),
          name: String.t(),
          owner_hash: String.t(),
          scopes: [String.t()]
        }

  @doc "Verifica firma y claims; devuelve los datos del personaje."
  @spec verify(String.t()) :: {:ok, claims()} | {:error, term()}
  def verify(token) do
    with {:ok, %{"kid" => kid, "alg" => alg}} when alg in @algorithms <- header(token),
         {:ok, jwk} <- key(kid),
         {true, %JOSE.JWT{fields: fields}, _jws} <- JOSE.JWT.verify_strict(jwk, [alg], token),
         :ok <- validate(fields) do
      {:ok, claims(fields)}
    else
      {:ok, %{"alg" => alg}} -> {:error, {:unsupported_alg, alg}}
      {false, _jwt, _jws} -> {:error, :invalid_signature}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  @doc "Borra la caché del JWKS (tests)."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache)
    :ok
  end

  defp header(token) do
    {:ok, token |> JOSE.JWS.peek_protected() |> Jason.decode!()}
  rescue
    _ -> {:error, :malformed_token}
  end

  # Primero la caché; ante un kid desconocido (rotación) se vuelve a pedir el JWKS.
  defp key(kid) do
    case find_key(cached_keys(), kid) do
      %JOSE.JWK{} = jwk -> {:ok, jwk}
      nil -> fetch_key(kid)
    end
  end

  defp fetch_key(kid) do
    with {:ok, keys} <- fetch_jwks() do
      case find_key(keys, kid) do
        %JOSE.JWK{} = jwk -> {:ok, jwk}
        nil -> {:error, {:unknown_kid, kid}}
      end
    end
  end

  defp find_key(keys, kid) do
    Enum.find_value(keys, fn key -> if key["kid"] == kid, do: JOSE.JWK.from_map(key) end)
  end

  defp cached_keys, do: :persistent_term.get(@cache, [])

  defp fetch_jwks do
    request = Req.new([retry: false] ++ (Sso.config(:req_options) || []))

    case Req.get(request, url: Sso.config(:jwks_url)) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} ->
        :persistent_term.put(@cache, keys)
        {:ok, keys}

      {:ok, %{status: status}} ->
        {:error, {:jwks_http, status}}

      {:error, exception} ->
        {:error, {:jwks_transport, Exception.message(exception)}}
    end
  end

  defp validate(fields) do
    audiences = List.wrap(fields["aud"])

    cond do
      fields["iss"] not in Sso.config(:issuers) -> {:error, :invalid_issuer}
      Sso.config(:client_id) not in audiences -> {:error, :invalid_audience}
      "EVE Online" not in audiences -> {:error, :invalid_audience}
      not is_integer(fields["exp"]) -> {:error, :missing_exp}
      fields["exp"] <= DateTime.to_unix(Clock.utc_now()) -> {:error, :expired}
      not match?("CHARACTER:EVE:" <> _, fields["sub"] || "") -> {:error, :invalid_subject}
      true -> :ok
    end
  end

  defp claims(fields) do
    "CHARACTER:EVE:" <> id = fields["sub"]

    %{
      character_id: String.to_integer(id),
      name: fields["name"],
      owner_hash: fields["owner"],
      scopes: fields["scp"] |> List.wrap() |> Enum.flat_map(&String.split(&1, " ", trim: true))
    }
  end
end
