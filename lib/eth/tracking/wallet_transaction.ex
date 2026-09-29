defmodule Eth.Tracking.WalletTransaction do
  @moduledoc """
  Transacción de mercado de la billetera de un personaje (`/characters/{id}/wallet/transactions`,
  ERS §7.2): la fuente del P&L real de los viajes (RF-7.5).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:transaction_id, :integer, autogenerate: false}
  schema "wallet_transactions" do
    field :character_id, :integer
    field :date, :utc_datetime
    field :type_id, :integer
    field :quantity, :integer
    field :unit_price, :float
    field :is_buy, :boolean
    field :location_id, :integer
    field :journal_ref_id, :integer
  end

  @doc "Fila para `Repo.insert_all/3` a partir del JSON de ESI."
  @spec row(pos_integer(), map()) :: map()
  def row(character_id, t) do
    {:ok, date, _} = DateTime.from_iso8601(t["date"])

    %{
      transaction_id: t["transaction_id"],
      character_id: character_id,
      date: DateTime.truncate(date, :second),
      type_id: t["type_id"],
      quantity: t["quantity"],
      unit_price: t["unit_price"] / 1,
      is_buy: t["is_buy"] == true,
      location_id: t["location_id"],
      journal_ref_id: t["journal_ref_id"]
    }
  end
end
