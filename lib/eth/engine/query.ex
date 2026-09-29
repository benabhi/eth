defmodule Eth.Engine.Query do
  @moduledoc """
  Personalización en tiempo de consulta (RF-4.14, RF-6.4): sobre las oportunidades
  universales aplica impuestos del piloto, capital, bodega, modo de ruta, triángulo
  (piloto → origen → destino), tiempo, ISK/h, Certeza y TVS; después filtra y ordena.

  Solo se vuelve a recorrer el libro si cambia el impuesto o hay límites de capital o
  bodega; si no, se reutiliza el cálculo universal.

  Implementa: RF-2.8, RF-4.6, RF-4.12, RF-4.14, RF-6.2, RF-6.4.
  """

  alias Eth.Engine.{Book, Fees, Opportunity, Score}
  alias Eth.{GameRules, Routing}

  @sorts [:tvs, :profit, :isk_per_hour, :roi, :jumps, :cost, :age]

  @type params :: %{
          optional(:accounting) => 0..5,
          optional(:capital) => number() | nil,
          optional(:cargo_m3) => number() | nil,
          optional(:route_mode) => :shortest | :secure,
          optional(:base_system_id) => pos_integer(),
          optional(:ship_class) => atom(),
          optional(:max_jumps) => pos_integer() | nil,
          optional(:min_profit) => number(),
          optional(:min_roi) => number(),
          optional(:search) => String.t(),
          optional(:sort) => atom(),
          optional(:limit) => pos_integer()
        }

  @doc "Ordenamientos válidos."
  @spec sorts() :: [atom()]
  def sorts, do: @sorts

  @doc "Parámetros por defecto del modo invitado."
  @spec defaults() :: map()
  def defaults do
    %{
      accounting: GameRules.get(:guest_accounting_level),
      capital: nil,
      cargo_m3: GameRules.get(:guest_cargo_m3),
      # Segura por defecto: la seguridad del jugador primero (ERS §2.6).
      route_mode: :secure,
      base_system_id: GameRules.get(:route_root_system_id),
      ship_class: GameRules.get(:guest_ship_class),
      max_jumps: nil,
      min_profit: GameRules.get(:min_profit_isk),
      min_roi: 0.0,
      search: "",
      sort: :tvs,
      limit: 200
    }
  end

  @doc """
  Devuelve `{filas, total}`: las primeras `limit` filas según el orden y el total de
  oportunidades que cumplen los filtros.
  """
  @spec run([Opportunity.t()], params(), DateTime.t()) :: {[map()], non_neg_integer()}
  def run(opportunities, params, now) do
    p = Map.merge(defaults(), params)
    search = normalize(p.search)

    rows =
      opportunities
      |> Stream.filter(&matches?(&1, search))
      |> Stream.map(&personalize(&1, p, now))
      |> Enum.filter(&(&1 && keep?(&1, p)))

    {rows |> sort(p.sort) |> Enum.take(p.limit), length(rows)}
  end

  @doc "Personaliza una oportunidad (`nil` si no es viable con estos parámetros)."
  @spec personalize(Opportunity.t(), map(), DateTime.t()) :: map() | nil
  def personalize(%Opportunity{} = opp, p, now) do
    with jumps when is_integer(jumps) <- route_jumps(opp, p.route_mode),
         to_origin when is_integer(to_origin) <-
           Routing.distance(p.base_system_id, opp.origin.system_id, p.route_mode),
         result = recompute(opp, p),
         true <- result.quantity > 0 and result.profit >= p.min_profit,
         age_min = DateTime.diff(now, opp.last_modified, :second) / 60,
         data_certainty when data_certainty > 0 <- Score.data_certainty(age_min) do
      stops = if opp.origin.location_id == opp.destination.location_id, do: 1, else: 2
      seconds = Score.travel_seconds(to_origin + jumps, stops, p.ship_class)
      isk_per_hour = Score.isk_per_hour(result.profit, seconds)
      roi = result.profit / result.cost
      order_certainty = Score.order_certainty(seconds / 60)
      liquidity = GameRules.get(:default_liquidity)

      utility =
        Score.utility(%{
          isk_per_hour: isk_per_hour,
          profit: result.profit,
          roi: roi,
          liquidity: liquidity
        })

      access_certainty = access_certainty(opp)
      certainty = order_certainty * data_certainty * access_certainty

      %{
        opportunity: opp,
        id: opp.id,
        quantity: result.quantity,
        cost: result.cost,
        revenue: result.revenue,
        tax: result.tax,
        tax_rate: Fees.sales_tax(p.accounting),
        profit: result.profit,
        avg_buy: result.avg_buy,
        avg_sell: result.avg_sell,
        roi: roi,
        cargo_m3: result.quantity * opp.unit_volume,
        jumps_to_origin: to_origin,
        jumps: jumps,
        total_jumps: to_origin + jumps,
        seconds: seconds,
        isk_per_hour: isk_per_hour,
        age_min: age_min,
        utility: utility,
        certainty: certainty,
        tvs: Score.tvs(utility, certainty),
        breakdown: %{
          liquidity: liquidity,
          order_certainty: order_certainty,
          data_certainty: data_certainty,
          access_certainty: access_certainty
        }
      }
    else
      _ -> nil
    end
  end

  # Órdenes en estructuras con mercado público: acceso sujeto a ACL (ERS §8.9).
  defp access_certainty(opp) do
    if opp.origin.structure or opp.destination.structure,
      do: GameRules.get(:structure_access_certainty),
      else: 1.0
  end

  defp route_jumps(opp, :secure), do: opp.secure_jumps
  defp route_jumps(opp, _shortest), do: opp.jumps

  defp recompute(opp, p) do
    guest? = p.accounting == GameRules.get(:guest_accounting_level)
    fits? = is_nil(p.cargo_m3) or opp.quantity * opp.unit_volume <= p.cargo_m3

    if guest? and is_nil(p.capital) and fits? do
      %{
        quantity: opp.quantity,
        cost: opp.cost,
        revenue: opp.revenue,
        tax: opp.tax,
        profit: opp.profit,
        avg_buy: opp.avg_buy,
        avg_sell: opp.avg_sell
      }
    else
      Book.walk(opp.asks, opp.bids, Fees.sales_tax(p.accounting), %{
        capital: p.capital || :infinity,
        cargo_m3: p.cargo_m3 || :infinity,
        unit_volume: opp.unit_volume,
        min_unit_margin: GameRules.get(:min_unit_margin_isk)
      })
    end
  end

  defp keep?(row, p) do
    row.roi >= p.min_roi and (is_nil(p.max_jumps) or row.total_jumps <= p.max_jumps)
  end

  defp matches?(_opp, ""), do: true

  defp matches?(opp, search) do
    [
      opp.type_name,
      opp.origin.name,
      opp.origin.system_name,
      opp.origin.region_name,
      opp.destination.name,
      opp.destination.system_name,
      opp.destination.region_name
    ]
    |> Enum.any?(&(&1 && String.contains?(normalize(&1), search)))
  end

  # Sin mayúsculas ni acentos (RF-6.4).
  defp normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.trim()
  end

  defp sort(rows, :jumps), do: Enum.sort_by(rows, &{&1.total_jumps, -&1.tvs})
  defp sort(rows, :cost), do: Enum.sort_by(rows, &{-&1.cost, -&1.tvs})
  defp sort(rows, :age), do: Enum.sort_by(rows, &{&1.age_min, -&1.tvs})
  defp sort(rows, field), do: Enum.sort_by(rows, &{-Map.fetch!(&1, field), -&1.profit})
end
