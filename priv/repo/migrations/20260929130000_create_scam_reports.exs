defmodule Eth.Repo.Migrations.CreateScamReports do
  use Ecto.Migration

  # "Reportar falso positivo" del anti-scam: registro local para calibrar umbrales
  # (RF-4.8, ERS §7.2).
  def change do
    create table(:scam_reports) do
      add :opportunity_snapshot, :map, null: false
      add :reason, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
