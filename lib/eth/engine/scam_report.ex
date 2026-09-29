defmodule Eth.Engine.ScamReport do
  @moduledoc """
  Reporte de falso positivo del escudo anti-scam (RF-4.8, ERS §7.2): una foto de la
  oportunidad tal como se evaluó (precios, estado, motivos y medianas) y un comentario
  opcional. Es un registro local para calibrar los umbrales de §8.7.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "scam_reports" do
    field :opportunity_snapshot, :map
    field :reason, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Changeset de un reporte nuevo."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:opportunity_snapshot, :reason])
    |> validate_required([:opportunity_snapshot])
    |> validate_length(:reason, max: 1_000)
  end

  @doc "Foto serializable de una fila personalizada (`Eth.Engine.Query.personalize/3`)."
  @spec snapshot(map()) :: map()
  def snapshot(row) do
    opp = row.opportunity
    dest = row.history.destination
    origin = row.history.origin

    %{
      "opportunity_id" => opp.id,
      "type_id" => opp.type_id,
      "type_name" => opp.type_name,
      "origin_location_id" => opp.origin.location_id,
      "origin_region_id" => opp.origin.region_id,
      "destination_location_id" => opp.destination.location_id,
      "destination_region_id" => opp.destination.region_id,
      "quantity" => row.quantity,
      "avg_buy" => row.avg_buy,
      "avg_sell" => row.avg_sell,
      "roi" => row.roi,
      "bids" => Enum.map(row.bids_used, &Tuple.to_list/1),
      "asks" => Enum.map(row.asks_used, &Tuple.to_list/1),
      "bid_issued" => opp.bid_issued && DateTime.to_iso8601(opp.bid_issued),
      "status" => Atom.to_string(row.shield.status),
      "reasons" => row.shield.reasons,
      "ratio" => row.shield.ratio,
      "destination_median_7d" => dest && dest.median_7d,
      "destination_median_30d" => dest && dest.median_30d,
      "origin_median_7d" => origin && origin.median_7d
    }
  end
end
