defmodule Eth.Repo.Migrations.CreateSystemEvents do
  use Ecto.Migration

  # Registro de eventos del sistema (RF-8.7), retención de 7 días.
  def change do
    create table(:system_events) do
      add :at, :utc_datetime_usec, null: false
      add :level, :string, null: false
      add :source, :string, null: false
      add :message, :text, null: false
      add :metadata, :map, null: false, default: %{}
    end

    create index(:system_events, [:at])
  end
end
