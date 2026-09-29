defmodule Eth.Repo.Migrations.CreateStructures do
  use Ecto.Migration

  # Estructuras Upwell con mercado y acceso por personaje (RF-1.6, RF-9.6, ERS §7.2).
  # Durables: las agregadas por el operador y el override de broker fee no se regeneran.
  def change do
    create table(:structures, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string
      add :solar_system_id, :integer
      add :region_id, :integer
      add :type_id, :integer
      add :owner_id, :integer
      # En la lista pública de ESI (/universe/structures?filter=market).
      add :public_market, :boolean, null: false, default: false
      # Agregada o elegida por el operador (se sigue aunque no esté en el top).
      add :followed, :boolean, null: false, default: false
      add :broker_fee_override, :float
      add :orders_count, :integer
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:structures, [:region_id])

    create table(:structure_access, primary_key: false) do
      add :structure_id, references(:structures, type: :bigint, on_delete: :delete_all),
        primary_key: true

      add :character_id, references(:characters, type: :bigint, on_delete: :delete_all),
        primary_key: true

      # ok | forbidden | unknown
      add :status, :string, null: false
      add :checked_at, :utc_datetime, null: false
      add :last_error, :string
    end
  end
end
