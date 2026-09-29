defmodule Eth.Repo.Migrations.CreateTradeRuns do
  use Ecto.Migration

  # Viajes (RF-7.1 a RF-7.6) y transacciones de la billetera para el P&L real (ERS §7.2).
  # Durables: son el historial de resultados del piloto.
  def change do
    create table(:trade_runs) do
      add :character_id, references(:characters, type: :bigint, on_delete: :delete_all),
        null: false

      # planned | to_origin | bought | in_transit | at_destination | closed | aborted
      add :status, :string, null: false
      # Plan congelado al iniciar: tipo, cantidad, estaciones, precios, ruta y proyección.
      add :plan, :map, null: false
      add :predicted_profit, :float, null: false
      add :realized_profit, :float
      # Resultado de la reconciliación con la billetera (RF-7.5).
      add :result, :map
      add :wallet_at_start, :float
      # Momento de cada etapa: %{"to_origin" => iso8601, ...}
      add :stages, :map, null: false, default: %{}
      add :close_reason, :string
      add :started_at, :utc_datetime, null: false
      add :closed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:trade_runs, [:character_id, :started_at])

    # Un viaje activo por personaje (RF-7.1).
    create unique_index(:trade_runs, [:character_id],
             where: "status NOT IN ('closed', 'aborted')",
             name: :trade_runs_one_active_index
           )

    create table(:wallet_transactions, primary_key: false) do
      add :transaction_id, :bigint, primary_key: true

      add :character_id, references(:characters, type: :bigint, on_delete: :delete_all),
        null: false

      add :date, :utc_datetime, null: false
      add :type_id, :integer, null: false
      add :quantity, :integer, null: false
      add :unit_price, :float, null: false
      add :is_buy, :boolean, null: false
      add :location_id, :bigint, null: false
      add :journal_ref_id, :bigint
    end

    create index(:wallet_transactions, [:character_id, :date])
  end
end
