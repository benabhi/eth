defmodule Eth.Repo.Migrations.CreateAppState do
  use Ecto.Migration

  # Estado de la aplicación clave-valor (ERS §7.2): cursor de R2Z2 y otros marcadores.
  def change do
    create table(:app_state, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :map, null: false

      timestamps(type: :utc_datetime, inserted_at: false)
    end
  end
end
