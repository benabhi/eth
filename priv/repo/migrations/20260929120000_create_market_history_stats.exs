defmodule Eth.Repo.Migrations.CreateMarketHistoryStats do
  use Ecto.Migration

  # Estadísticas del historial de mercado por (región, tipo) (RF-1.12, ERS §7.2).
  # Regenerables: se pueden borrar sin pérdida (ERS §7.3).
  def change do
    create table(:market_history_stats, primary_key: false) do
      add :region_id, :integer, primary_key: true
      add :type_id, :integer, primary_key: true
      add :as_of, :date, null: false
      add :median_7d, :float
      add :median_30d, :float
      add :avg_7d, :float
      add :avg_30d, :float
      add :stddev_30d, :float
      add :volume_avg_7d, :float, null: false
      add :volume_avg_30d, :float, null: false
      add :days_traded_30d, :integer, null: false
      add :daily_avg, {:array, :float}, null: false
      add :daily_volume, {:array, :bigint}, null: false
      add :fetched_at, :utc_datetime, null: false
    end

    create index(:market_history_stats, [:as_of])
  end
end
