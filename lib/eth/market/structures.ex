defmodule Eth.Market.Structures do
  @moduledoc """
  Registro de estructuras con mercado y acceso por personaje (RF-1.6, RF-9.6).

  - La lista pública de ESI marca `public_market`; el operador puede agregar estructuras
    privadas por ID (`followed`).
  - Nombre, sistema y región se completan con `/universe/structures/{id}` (requiere token).
  - Acceso por personaje: un 403 deja la estructura `forbidden` para ese personaje y no se
    vuelve a intentar antes de `@forbidden_retry_s` (nunca en bucle: consume el presupuesto
    de errores de ESI).
  - Selección a seguir: públicas de las regiones habilitadas, top `:structures_top` por
    órdenes, más las elegidas por el operador.

  Implementa: RF-1.6, RF-9.6.
  """

  import Ecto.Query

  alias Eth.{Clock, GameRules, Repo, Sde}
  alias Eth.Market.{Structure, StructureAccess}

  @forbidden_retry_s 24 * 3600

  @doc "Todas las estructuras registradas (con nombre primero)."
  @spec list() :: [Structure.t()]
  def list,
    do: Repo.all(from s in Structure, order_by: [desc_nulls_last: s.orders_count, asc: s.id])

  @doc "Estructura por ID."
  @spec get(pos_integer()) :: Structure.t() | nil
  def get(id), do: Repo.get(Structure, id)

  @doc """
  Sincroniza la lista pública: marca `public_market` en las de la lista (creándolas si
  hacía falta) y lo quita en las que ya no están.
  """
  @spec sync_public([pos_integer()]) :: :ok
  def sync_public(ids) do
    now = now()
    rows = for id <- ids, do: %{id: id, public_market: true, inserted_at: now, updated_at: now}

    Repo.insert_all(Structure, rows,
      on_conflict: {:replace, [:public_market, :updated_at]},
      conflict_target: :id
    )

    Repo.update_all(
      from(s in Structure, where: s.public_market and s.id not in ^ids),
      set: [public_market: false, updated_at: now]
    )

    :ok
  end

  @doc "Agrega una estructura elegida por el operador (privada o pública)."
  @spec follow(pos_integer()) :: {:ok, Structure.t()}
  def follow(id) do
    now = now()

    Repo.insert_all(Structure, [%{id: id, followed: true, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:followed, :updated_at]},
      conflict_target: :id
    )

    {:ok, get(id)}
  end

  @doc "Actualiza los ajustes del operador (seguir, broker fee)."
  @spec update_settings(Structure.t(), map()) ::
          {:ok, Structure.t()} | {:error, Ecto.Changeset.t()}
  def update_settings(%Structure{} = structure, attrs) do
    structure |> Structure.settings_changeset(attrs) |> Repo.update()
  end

  @doc "Estructuras sin sistema conocido (falta resolver sus datos)."
  @spec unresolved() :: [Structure.t()]
  def unresolved, do: Repo.all(from s in Structure, where: is_nil(s.solar_system_id))

  @doc "Guarda los datos de `/universe/structures/{id}`."
  @spec put_info(pos_integer(), map()) :: :ok
  def put_info(id, info) do
    system_id = info["solar_system_id"]

    Repo.update_all(from(s in Structure, where: s.id == ^id),
      set: [
        name: info["name"],
        solar_system_id: system_id,
        region_id: system_id && (Sde.system(system_id) || %{})[:region_id],
        type_id: info["type_id"],
        owner_id: info["owner_id"],
        last_seen_at: now(),
        updated_at: now()
      ]
    )

    :ok
  end

  @doc "Cantidad de órdenes del último ciclo (para elegir el top)."
  @spec put_orders_count(pos_integer(), non_neg_integer()) :: :ok
  def put_orders_count(id, count) do
    Repo.update_all(from(s in Structure, where: s.id == ^id),
      set: [orders_count: count, last_seen_at: now(), updated_at: now()]
    )

    :ok
  end

  @doc """
  Estructuras a seguir: públicas en regiones habilitadas, top `:structures_top` por
  órdenes (las nunca descargadas cuentan como 0), más las elegidas por el operador.
  Solo las que tienen sistema conocido.
  """
  @spec selection() :: [Structure.t()]
  def selection do
    known = Repo.all(from s in Structure, where: not is_nil(s.solar_system_id))

    top =
      known
      |> Enum.filter(
        &(&1.public_market and &1.region_id != nil and
            GameRules.scannable_region?(&1.region_id))
      )
      |> Enum.sort_by(&(-(&1.orders_count || 0)))
      |> Enum.take(GameRules.get(:structures_top))

    (top ++ Enum.filter(known, & &1.followed)) |> Enum.uniq_by(& &1.id)
  end

  ## Acceso por personaje

  @doc """
  Access token de un personaje para las tareas de fondo (su sesión lo mantiene vigente).
  En tests se reemplaza con `config :eth, :character_token_fun`.
  """
  @spec character_token(pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def character_token(character_id) do
    fun = Application.get_env(:eth, :character_token_fun, &Eth.Characters.Sessions.token/1)
    fun.(character_id)
  end

  @doc "Acceso de todos los personajes: `%{{structure_id, character_id} => acceso}`."
  @spec access_map() :: %{{pos_integer(), pos_integer()} => StructureAccess.t()}
  def access_map do
    StructureAccess |> Repo.all() |> Map.new(&{{&1.structure_id, &1.character_id}, &1})
  end

  @doc "Registra el resultado de un intento de acceso."
  @spec put_access(pos_integer(), pos_integer(), :ok | :forbidden | :unknown, String.t() | nil) ::
          :ok
  def put_access(structure_id, character_id, status, error \\ nil) do
    row = %{
      structure_id: structure_id,
      character_id: character_id,
      status: Atom.to_string(status),
      checked_at: now(),
      last_error: error
    }

    Repo.insert_all(StructureAccess, [row],
      on_conflict: {:replace, [:status, :checked_at, :last_error]},
      conflict_target: [:structure_id, :character_id]
    )

    :ok
  end

  @doc """
  ¿Se puede intentar con este personaje? Sí, salvo que tenga un 403 de hace menos de 24 h
  (CA de RF-1.6).
  """
  @spec may_try?(StructureAccess.t() | nil, DateTime.t()) :: boolean()
  def may_try?(%StructureAccess{status: "forbidden", checked_at: at}, now),
    do: DateTime.diff(now, at) >= @forbidden_retry_s

  def may_try?(_access, _now), do: true

  defp now, do: Clock.utc_now() |> DateTime.truncate(:second)
end
