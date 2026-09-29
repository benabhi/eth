defmodule Eth.Sso.Token do
  @moduledoc """
  Tokens de EVE SSO (RF-5.3): intercambio del código de autorización, renovación y
  revocación, con autenticación básica del cliente.

  El SSO **puede rotar el refresh token**: siempre se devuelve el que llegó en la
  respuesta para persistirlo.

  Implementa: RF-5.1, RF-5.3.
  """

  alias Eth.{Clock, Sso}
  alias Eth.Esi.Client

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: DateTime.t()
        }

  @doc "Intercambia el código de autorización por tokens."
  @spec exchange(String.t()) :: {:ok, tokens()} | {:error, term()}
  def exchange(code), do: request_tokens(grant_type: "authorization_code", code: code)

  @doc """
  Renueva el access token. `{:error, :invalid_grant}` significa que el refresh token ya
  no sirve (revocado o vencido): hay que volver a loguear.
  """
  @spec refresh(String.t()) :: {:ok, tokens()} | {:error, term()}
  def refresh(refresh_token) do
    request_tokens(grant_type: "refresh_token", refresh_token: refresh_token)
  end

  @doc "Revoca un refresh token (al olvidar un personaje, RNF-4.10)."
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(refresh_token) do
    case Req.post(request(),
           url: Sso.config(:revoke_url),
           form: [token_type_hint: "refresh_token", token: refresh_token]
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp request_tokens(form) do
    case Req.post(request(), url: Sso.config(:token_url), form: form) do
      {:ok, %{status: 200, body: %{"access_token" => access} = body}} ->
        {:ok,
         %{
           access_token: access,
           refresh_token: body["refresh_token"],
           expires_at: DateTime.add(Clock.utc_now(), body["expires_in"] || 1199, :second)
         }}

      {:ok, %{status: 400, body: %{"error" => "invalid_grant"}}} ->
        {:error, :invalid_grant}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp request do
    contact = Application.get_env(:eth, Eth.Esi.Client, [])[:contact]

    [
      auth: {:basic, "#{Sso.config(:client_id)}:#{Sso.config(:client_secret)}"},
      headers: [{"user-agent", Client.user_agent(contact)}],
      retry: false
    ]
    |> Keyword.merge(Sso.config(:req_options) || [])
    |> Req.new()
  end
end
