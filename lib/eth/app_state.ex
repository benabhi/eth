defmodule Eth.AppState do
  @moduledoc """
  Estado de la aplicación clave-valor en `app_state` (ERS §7.2): marcadores que deben
  sobrevivir a un reinicio, como el cursor del feed de killmails (RF-3.1).
  """

  import Ecto.Query

  alias Eth.Repo

  @doc "Valor guardado (mapa JSON) o `nil`."
  @spec get(String.t()) :: map() | nil
  def get(key) do
    Repo.one(from s in "app_state", where: s.key == ^key, select: s.value)
  end

  @doc "Guarda un valor (reemplaza el anterior)."
  @spec put(String.t(), map()) :: :ok
  def put(key, value) when is_map(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("app_state", [%{key: key, value: value, updated_at: now}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:key]
    )

    :ok
  end
end
