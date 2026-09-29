defmodule Eth.Sso.Strategy do
  @moduledoc """
  Estrategia Ueberauth propia para EVE SSO v2 (RF-5.1, decisión D-03: `ueberauth_eve_sso`
  no se mantiene desde 2019).

  - Solicitud: redirige al endpoint de autorización con los scopes configurados y el `state`
    anti-CSRF que gestiona Ueberauth.
  - Callback: intercambia el código, verifica el JWT y expone los datos en
    `conn.assigns.ueberauth_auth`.

  Implementa: RF-5.1, RNF-4.3.
  """
  use Ueberauth.Strategy, uid_field: :character_id

  alias Eth.Sso
  alias Ueberauth.Auth.{Credentials, Extra, Info}

  @impl Ueberauth.Strategy
  def handle_request!(conn) do
    if Sso.configured?() do
      params =
        [
          response_type: "code",
          client_id: Sso.config(:client_id),
          redirect_uri: Sso.config(:callback_url),
          scope: Enum.join(Sso.scopes(), " ")
        ]
        |> with_state_param(conn)

      redirect!(conn, Sso.config(:authorize_url) <> "?" <> URI.encode_query(params))
    else
      set_errors!(conn, [error("not_configured", "EVE SSO no está configurado")])
    end
  end

  @impl Ueberauth.Strategy
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    case Sso.login(code) do
      {:ok, login} -> put_private(conn, :eve_login, login)
      {:error, reason} -> set_errors!(conn, [error("sso", inspect(reason))])
    end
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "El SSO no devolvió el código de autorización")])
  end

  @impl Ueberauth.Strategy
  def handle_cleanup!(conn), do: put_private(conn, :eve_login, nil)

  @impl Ueberauth.Strategy
  def uid(conn), do: conn.private.eve_login.character_id

  @impl Ueberauth.Strategy
  def credentials(conn) do
    login = conn.private.eve_login

    %Credentials{
      token: login.access_token,
      refresh_token: login.refresh_token,
      expires: true,
      expires_at: DateTime.to_unix(login.expires_at),
      scopes: login.scopes
    }
  end

  @impl Ueberauth.Strategy
  def info(conn) do
    login = conn.private.eve_login

    %Info{
      name: login.name,
      image: "https://images.evetech.net/characters/#{login.character_id}/portrait?size=128"
    }
  end

  @impl Ueberauth.Strategy
  def extra(conn), do: %Extra{raw_info: %{login: conn.private.eve_login}}
end
