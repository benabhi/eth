defmodule EthWeb.AuthController do
  @moduledoc """
  Login con EVE SSO (RF-5.1) y selección del personaje activo (RF-5.10).

  El personaje activo vive en la sesión (cookie firmada, RNF-4.4); los tokens nunca van a
  la sesión: el refresh token se guarda cifrado y el access token solo en memoria.

  Implementa: RF-5.1, RF-5.10, RNF-4.4, RNF-4.5.
  """
  use EthWeb, :controller

  alias Eth.{Characters, Events, Sso}
  alias Eth.Characters.Sessions

  plug Ueberauth

  @doc "Solo se llega aquí si Ueberauth no pudo redirigir al SSO."
  def request(conn, _params) do
    conn
    |> put_flash(:error, not_configured_message())
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    reason = Enum.map_join(failure.errors, ", ", & &1.message)
    Events.emit(:warning, "SSO", "Login fallido: #{reason}")

    conn
    |> put_flash(:error, gettext("No se pudo iniciar sesión con EVE: %{reason}", reason: reason))
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    login = auth.extra.raw_info.login

    with true <- Sso.allowed?(login.character_id),
         {:ok, character} <- Characters.upsert_login(login) do
      Sessions.start(character.id, login)
      Events.emit(:action, "SSO", "Login de #{character.name}")

      conn
      |> configure_session(renew: true)
      |> put_session(:character_id, character.id)
      |> put_flash(:info, gettext("Sesión iniciada como %{name}", name: character.name))
      |> redirect(to: ~p"/")
    else
      false ->
        Events.emit(:warning, "SSO", "Login rechazado (fuera de la lista blanca): #{login.name}")

        conn
        |> put_flash(:error, gettext("Este personaje no está autorizado en esta instancia"))
        |> redirect(to: ~p"/")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("No se pudo guardar el personaje"))
        |> redirect(to: ~p"/")
    end
  end

  @doc "Cambia el personaje activo (debe estar vinculado)."
  def activate(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{} = character <- Characters.get(id) do
      conn
      |> put_session(:character_id, character.id)
      |> redirect(to: ~p"/")
    else
      _ -> conn |> put_flash(:error, gettext("Personaje desconocido")) |> redirect(to: ~p"/")
    end
  end

  @doc "Cierra la sesión (el personaje sigue vinculado; se puede reactivar)."
  def logout(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> delete_session(:character_id)
    |> redirect(to: ~p"/")
  end

  defp not_configured_message do
    gettext(
      "EVE SSO no está configurado: definí EVE_CLIENT_ID, EVE_CLIENT_SECRET y ETH_VAULT_KEY en .env y reiniciá."
    )
  end
end
