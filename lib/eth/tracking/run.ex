defmodule Eth.Tracking.Run do
  @moduledoc """
  Viaje de trading (RF-7.1, ERS §7.2): el plan congelado al iniciar (un tipo, una compra y
  una venta, D-18), su etapa, la proyección y el resultado real reconciliado.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @statuses ~w(planned to_origin bought in_transit at_destination closed aborted)
  @active ~w(planned to_origin bought in_transit at_destination)

  schema "trade_runs" do
    field :character_id, :integer
    field :status, :string
    field :plan, :map
    field :predicted_profit, :float
    field :realized_profit, :float
    field :result, :map
    field :wallet_at_start, :float
    field :stages, :map, default: %{}
    field :close_reason, :string
    field :started_at, :utc_datetime
    field :closed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Etapas posibles."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "¿El viaje sigue en curso?"
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}), do: status in @active

  @doc "Etapas en curso."
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active
end
