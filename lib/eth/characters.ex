defmodule Eth.Characters do
  @moduledoc """
  Personajes vinculados por EVE SSO y perfiles de carga de naves (RF-5.1, RF-5.3, RF-5.8,
  RF-5.10). API pública del contexto: la web nunca toca el `Repo` directamente.

  Implementa: RF-5.1, RF-5.3, RF-5.8, RF-5.10, RNF-4.10.
  """

  import Ecto.Query

  alias Eth.Characters.{Character, ShipProfile}
  alias Eth.{Clock, Events, Repo, Sso}
  alias Eth.Sso.Token

  ## Personajes

  @doc "Personajes vinculados, por nombre."
  @spec list() :: [Character.t()]
  def list, do: Repo.all(from c in Character, order_by: c.name)

  @doc "Personaje por ID (`nil` si no existe)."
  @spec get(pos_integer()) :: Character.t() | nil
  def get(id), do: Repo.get(Character, id)

  @doc """
  Guarda o actualiza el personaje tras un login verificado. Si cambió el `owner_hash`
  (personaje transferido a otra cuenta), se registra el evento: sus datos personales se
  reemplazan por los del login nuevo (RF-5.3).
  """
  @spec upsert_login(Sso.login()) :: {:ok, Character.t()} | {:error, Ecto.Changeset.t()}
  def upsert_login(login) do
    previous = get(login.character_id)

    if previous && previous.owner_hash != login.owner_hash do
      Events.emit(
        :warning,
        "Personajes",
        "#{login.name} cambió de cuenta: se reinician sus datos"
      )
    end

    attrs = %{
      id: login.character_id,
      name: login.name,
      owner_hash: login.owner_hash,
      scopes: login.scopes,
      refresh_token: login.refresh_token,
      token_status: "ok",
      last_login_at: DateTime.truncate(Clock.utc_now(), :second)
    }

    %Character{}
    |> Character.login_changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:name, :owner_hash, :scopes, :refresh_token, :token_status, :last_login_at, :updated_at]},
      conflict_target: :id,
      returning: true
    )
  end

  @doc "Persiste el refresh token rotado por el SSO (RF-5.3)."
  @spec update_refresh_token(pos_integer(), String.t()) :: :ok
  def update_refresh_token(id, refresh_token) do
    # El tipo del campo (Eth.Encrypted.Binary) cifra al guardar: se pasa en claro.
    from(c in Character, where: c.id == ^id)
    |> Repo.update_all(set: [refresh_token: refresh_token, token_status: "ok"])

    :ok
  end

  @doc "Marca que el personaje debe volver a loguear (token revocado o vencido)."
  @spec mark_relogin(pos_integer()) :: :ok
  def mark_relogin(id) do
    from(c in Character, where: c.id == ^id) |> Repo.update_all(set: [token_status: "relogin"])
    :ok
  end

  @doc "Olvida un personaje: revoca su token en el SSO y borra sus datos (RNF-4.10)."
  @spec forget(pos_integer()) :: :ok
  def forget(id) do
    case get(id) do
      nil ->
        :ok

      character ->
        if character.refresh_token, do: Token.revoke(character.refresh_token)
        Repo.delete!(character)
        Events.emit(:action, "Usuario", "Personaje olvidado: #{character.name}")
        :ok
    end
  end

  ## Perfiles de nave (RF-5.8)

  @doc "Perfil de una nave: primero el de la nave concreta, después el del casco."
  @spec ship_profile(pos_integer() | nil, pos_integer()) :: ShipProfile.t() | nil
  def ship_profile(ship_item_id, ship_type_id) do
    (ship_item_id && Repo.get_by(ShipProfile, ship_item_id: ship_item_id)) ||
      Repo.one(
        from p in ShipProfile, where: p.ship_type_id == ^ship_type_id and is_nil(p.ship_item_id)
      )
  end

  @doc "Changeset vacío para el formulario de perfil."
  @spec change_ship_profile(map()) :: Ecto.Changeset.t()
  def change_ship_profile(attrs \\ %{}), do: ShipProfile.changeset(%ShipProfile{}, attrs)

  @doc """
  Guarda el perfil de una nave. Con `apply_to_hull: true` se guarda como perfil del casco
  (sirve para todas las naves de ese tipo sin perfil propio).
  """
  @spec save_ship_profile(pos_integer() | nil, pos_integer(), map(), keyword()) ::
          {:ok, ShipProfile.t()} | {:error, Ecto.Changeset.t()}
  def save_ship_profile(ship_item_id, ship_type_id, attrs, opts \\ []) do
    item_id = if opts[:apply_to_hull], do: nil, else: ship_item_id
    existing = ship_profile(item_id, ship_type_id)

    profile =
      if existing && existing.ship_item_id == item_id,
        do: existing,
        else: %ShipProfile{ship_item_id: item_id, ship_type_id: ship_type_id}

    profile |> ShipProfile.changeset(attrs) |> Repo.insert_or_update()
  end

  @doc "Perfiles de nave guardados."
  @spec list_ship_profiles() :: [ShipProfile.t()]
  def list_ship_profiles, do: Repo.all(from p in ShipProfile, order_by: [p.ship_type_id, p.id])
end
