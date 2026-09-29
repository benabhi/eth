defmodule Eth.Market.Structure do
  @moduledoc """
  Estructura Upwell con mercado (RF-1.6, ERS §7.2): nombre, sistema y región (de
  `/universe/structures/{id}`), si está en la lista pública, si el operador la sigue,
  override de broker fee (RF-9.4) y cantidad de órdenes del último ciclo.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :integer, autogenerate: false}
  schema "structures" do
    field :name, :string
    field :solar_system_id, :integer
    field :region_id, :integer
    field :type_id, :integer
    field :owner_id, :integer
    field :public_market, :boolean, default: false
    field :followed, :boolean, default: false
    field :broker_fee_override, :float
    field :orders_count, :integer
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de los ajustes que edita el operador (RF-9.6)."
  @spec settings_changeset(t(), map()) :: Ecto.Changeset.t()
  def settings_changeset(structure, attrs) do
    structure
    |> cast(attrs, [:followed, :broker_fee_override])
    |> validate_number(:broker_fee_override,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1
    )
  end
end
