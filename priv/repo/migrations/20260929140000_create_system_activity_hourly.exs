defmodule Eth.Repo.Migrations.CreateSystemActivityHourly do
  use Ecto.Migration

  # Instantáneas horarias de /universe/system_kills y /universe/system_jumps para la línea
  # base del radar (RF-3.4, ERS §7.2). Solo se guardan los sistemas con actividad: uno
  # ausente en una hora muestreada tuvo 0. Retención de 30 días; regenerable.
  def change do
    create table(:system_activity_hourly, primary_key: false) do
      add :solar_system_id, :integer, primary_key: true
      add :hour, :utc_datetime, primary_key: true
      add :ship_kills, :integer, null: false, default: 0
      add :pod_kills, :integer, null: false, default: 0
      add :npc_kills, :integer, null: false, default: 0
      add :jumps, :integer, null: false, default: 0
    end

    create index(:system_activity_hourly, [:hour])

    # Horas efectivamente muestreadas por fuente (kills o saltos): distingue "0 kills" de
    # "sin dato".
    create table(:system_activity_samples, primary_key: false) do
      add :source, :string, primary_key: true
      add :hour, :utc_datetime, primary_key: true
    end
  end
end
