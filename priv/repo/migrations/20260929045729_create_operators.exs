defmodule Eth.Repo.Migrations.CreateOperators do
  use Ecto.Migration

  # Operador (modo de operador único, ERS §2.3 y §7.2): sus ajustes viven en `settings`
  # (jsonb), p. ej. los overrides de las reglas del juego (RF-9.4).
  def change do
    create table(:operators) do
      add :name, :string, null: false
      add :settings, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end
  end
end
