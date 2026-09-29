defmodule Eth.Repo.Migrations.CreateCharacters do
  use Ecto.Migration

  # Personajes vinculados por EVE SSO (ERS §7.2). El ID es el character_id de EVE.
  def change do
    create table(:characters, primary_key: false) do
      add :id, :bigint, primary_key: true
      add :name, :string, null: false
      add :owner_hash, :string, null: false
      add :scopes, {:array, :string}, null: false, default: []
      # Refresh token cifrado con Eth.Vault (RNF-4.2).
      add :refresh_token, :binary
      add :token_status, :string, null: false, default: "ok"
      add :last_login_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
