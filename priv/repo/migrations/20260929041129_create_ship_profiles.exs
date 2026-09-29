defmodule Eth.Repo.Migrations.CreateShipProfiles do
  use Ecto.Migration

  # Perfiles de capacidad de carga por nave (RF-5.8, ERS §7.2).
  def change do
    create table(:ship_profiles) do
      add :ship_item_id, :bigint
      add :ship_type_id, :integer, null: false
      add :name, :string
      add :cargo_m3, :float, null: false
      add :evasion_class, :string, null: false
      add :max_cargo_value, :float

      timestamps(type: :utc_datetime)
    end

    # Una nave concreta tiene un solo perfil; el perfil sin ship_item_id es el del casco.
    create unique_index(:ship_profiles, [:ship_item_id])

    create unique_index(:ship_profiles, [:ship_type_id],
             where: "ship_item_id IS NULL",
             name: :ship_profiles_hull_index
           )
  end
end
