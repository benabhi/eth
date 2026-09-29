defmodule Eth.Market.HistoryStat do
  @moduledoc """
  Fila persistida de `market_history_stats` (RF-1.12, ERS §7.2): las estadísticas de
  `Eth.Market.HistoryStats` por `(region_id, type_id)`. Es la copia durable de la caché
  ETS de `Eth.Market.History` (regenerable, ERS §7.3).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "market_history_stats" do
    field :region_id, :integer, primary_key: true
    field :type_id, :integer, primary_key: true
    field :as_of, :date
    field :median_7d, :float
    field :median_30d, :float
    field :avg_7d, :float
    field :avg_30d, :float
    field :stddev_30d, :float
    field :volume_avg_7d, :float
    field :volume_avg_30d, :float
    field :days_traded_30d, :integer
    field :daily_avg, {:array, :float}
    field :daily_volume, {:array, :integer}
    field :fetched_at, :utc_datetime
  end

  @stat_fields [
    :as_of,
    :median_7d,
    :median_30d,
    :avg_7d,
    :avg_30d,
    :stddev_30d,
    :volume_avg_7d,
    :volume_avg_30d,
    :days_traded_30d,
    :daily_avg,
    :daily_volume
  ]

  @doc "Campos de estadísticas (los de `Eth.Market.HistoryStats.t()`)."
  @spec stat_fields() :: [atom()]
  def stat_fields, do: @stat_fields

  @doc "Fila para `Repo.insert_all/3` a partir de las estadísticas calculadas."
  @spec row(pos_integer(), pos_integer(), map(), DateTime.t()) :: map()
  def row(region_id, type_id, stats, fetched_at) do
    stats
    |> Map.take(@stat_fields)
    |> Map.merge(%{
      region_id: region_id,
      type_id: type_id,
      fetched_at: DateTime.truncate(fetched_at, :second)
    })
  end

  @doc "Estadísticas (mapa de `Eth.Market.HistoryStats`) a partir de una fila."
  @spec to_stats(t()) :: map()
  def to_stats(%__MODULE__{} = row), do: Map.take(row, @stat_fields)
end
