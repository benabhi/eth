defmodule Eth.Sso do
  @moduledoc """
  Login con EVE SSO (RF-5.1): configuración, intercambio del código de autorización y
  verificación del JWT. Los detalles de transporte están en `Eth.Sso.Token` y la
  verificación en `Eth.Sso.Jwt`.

  Implementa: RF-5.1, RF-5.2, RNF-4.3.
  """

  alias Eth.Sso.{Jwt, Token}

  @type login :: %{
          character_id: pos_integer(),
          name: String.t(),
          owner_hash: String.t(),
          scopes: [String.t()],
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: DateTime.t()
        }

  @doc "Configuración del SSO."
  @spec config() :: keyword()
  def config, do: Application.get_env(:eth, __MODULE__, [])

  @doc "Valor de configuración."
  @spec config(atom()) :: term()
  def config(key), do: Keyword.get(config(), key)

  @doc "¿Está todo listo para loguear? (credenciales de la app y bóveda de tokens)"
  @spec configured?() :: boolean()
  def configured? do
    config(:client_id) not in [nil, ""] and config(:client_secret) not in [nil, ""] and
      Eth.Vault.configured?()
  end

  @doc "Scopes que pide la aplicación (RF-5.2)."
  @spec scopes() :: [String.t()]
  def scopes, do: config(:scopes)

  @doc "¿El personaje puede loguear? Con lista blanca vacía, cualquiera (RNF-4.5)."
  @spec allowed?(pos_integer()) :: boolean()
  def allowed?(character_id) do
    case config(:allowed_character_ids) do
      list when list in [nil, []] -> true
      list -> character_id in list
    end
  end

  @doc "Intercambia el código del callback por tokens y verifica el JWT."
  @spec login(String.t()) :: {:ok, login()} | {:error, term()}
  def login(code) do
    with {:ok, tokens} <- Token.exchange(code),
         {:ok, claims} <- Jwt.verify(tokens.access_token) do
      {:ok, Map.merge(claims, tokens)}
    end
  end

  @doc "Scopes requeridos que el personaje no concedió."
  @spec missing_scopes([String.t()]) :: [String.t()]
  def missing_scopes(granted), do: scopes() -- granted
end
