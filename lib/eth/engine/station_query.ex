defmodule Eth.Engine.StationQuery do
  @moduledoc """
  Personalización del station trading en tiempo de consulta (RF-4.16, RF-4.14).

  Sobre los candidatos universales aplica las comisiones del piloto (sales tax por
  Accounting; broker por Broker Relations y sus standings con la corporación dueña de la
  estación y su facción), descarta sus propias órdenes, cotiza precios legales,
  calcula la competencia y el plan diario con el volumen de 7 días del historial, y
  evalúa el escudo anti-scam. Sin historial un tipo no se propone (CA de RF-4.16).

  **Certeza** = frescura de los datos × anti-scam × competencia. El orden por defecto
  es el beneficio estimado por día ponderado por la Certeza (`score`).

  Implementa: RF-4.14, RF-4.16.
  """

  alias Eth.Engine.{Fees, Query, Score, Search, Shield, StationOpportunity, StationTrading}
  alias Eth.{GameRules, Sde}
  alias Eth.Market.{History, Prices}

  @sorts [:score, :profit_day, :margin, :volume, :age]

  @type params :: %{
          optional(:accounting) => 0..5,
          optional(:broker_relations) => 0..5,
          optional(:standings) => %{pos_integer() => number()},
          optional(:capital) => number() | nil,
          optional(:location_id) => pos_integer() | nil,
          optional(:min_margin) => number(),
          optional(:min_daily_volume) => number(),
          optional(:min_profit_day) => number(),
          optional(:own_order_ids) => MapSet.t(),
          optional(:shield) => :all | :hide_scam | :safe,
          optional(:search) => String.t(),
          optional(:sort) => atom(),
          optional(:limit) => pos_integer()
        }

  @doc "Ordenamientos válidos."
  @spec sorts() :: [atom()]
  def sorts, do: @sorts

  @doc "Parámetros por defecto (modo invitado)."
  @spec defaults() :: map()
  def defaults do
    rules = GameRules.get(:station_trading)

    %{
      accounting: GameRules.get(:guest_accounting_level),
      broker_relations: GameRules.get(:guest_broker_relations_level),
      standings: %{},
      capital: nil,
      location_id: nil,
      min_margin: rules.min_margin,
      min_daily_volume: rules.min_daily_volume,
      min_profit_day: 0,
      own_order_ids: MapSet.new(),
      shield: :hide_scam,
      search: "",
      sort: :score,
      limit: 200
    }
  end

  @doc "Devuelve `{filas, total}` como `Eth.Engine.Query.run/3`."
  @spec run([StationOpportunity.t()], params(), DateTime.t()) :: {[map()], non_neg_integer()}
  def run(opportunities, params, now) do
    p = Map.merge(defaults(), params)
    search = Query.normalize(p.search)

    # Comisiones una vez por estación (son pocas: los hubs).
    rows =
      opportunities
      |> Stream.filter(&(is_nil(p.location_id) or &1.location.location_id == p.location_id))
      |> Stream.filter(&matches?(&1, search))
      |> Stream.map(&{&1, History.stats(&1.location.region_id, &1.type_id)})
      # Primero lo barato: sin historial suficiente no se propone (la mayoría).
      |> Stream.filter(fn {_opp, stats} -> liquid_enough?(stats, p) end)
      |> Enum.reduce({[], %{}}, fn {opp, stats}, {acc, fees_cache} ->
        loc = opp.location.location_id
        fees = Map.get_lazy(fees_cache, loc, fn -> fees(loc, p) end)
        row = build(opp, stats, fees, p, now)
        acc = if row && keep?(row, p), do: [row | acc], else: acc
        {acc, Map.put(fees_cache, loc, fees)}
      end)
      |> elem(0)

    {rows |> sort(p.sort) |> Enum.take(p.limit), length(rows)}
  end

  @doc """
  Primeras `limit` filas según el orden pedido. Sirve para combinar resultados parciales
  de `run/3` calculados en paralelo (`Eth.Engine`, RNF-1.1).
  """
  @spec top([map()], params()) :: [map()]
  def top(rows, params) do
    p = Map.merge(defaults(), params)
    rows |> sort(p.sort) |> Enum.take(p.limit)
  end

  @doc "Personaliza un candidato (`nil` si no deja margen o no tiene historial)."
  @spec personalize(StationOpportunity.t(), map(), DateTime.t()) :: map() | nil
  def personalize(%StationOpportunity{} = opp, p, now) do
    p = Map.merge(defaults(), p)
    stats = History.stats(opp.location.region_id, opp.type_id)
    build(opp, stats, fees(opp.location.location_id, p), p, now)
  end

  @doc """
  Función `{región, tipo} -> boolean` que dice si un par tiene historial con volumen
  suficiente para estos parámetros (prefiltro barato de `Eth.Engine.station_query/1`).
  """
  @spec liquid_pair_fun(map()) :: ({pos_integer(), pos_integer()} -> boolean())
  def liquid_pair_fun(params) do
    p = Map.merge(defaults(), params)
    fn {region_id, type_id} -> liquid_enough?(History.stats(region_id, type_id), p) end
  end

  defp liquid_enough?(%{volume_avg_7d: volume}, p), do: volume >= p.min_daily_volume
  defp liquid_enough?(_stats, _p), do: false

  defp build(opp, stats, fees, p, now) do
    age_min = DateTime.diff(now, opp.last_modified, :second) / 60

    with %{} = q <- StationTrading.quote(opp, fees, p.own_order_ids),
         %{volume_avg_7d: daily_volume} <- stats,
         true <- StationTrading.realistic?(q, stats),
         data_certainty when data_certainty > 0 <- Score.data_certainty(age_min) do
      plan = StationTrading.plan(q, daily_volume, p.capital)
      shield = shield(opp, q, stats, p.own_order_ids, now)
      scam_certainty = Shield.certainty(shield.status)
      competition_certainty = StationTrading.competition_certainty(q.competition)
      certainty = data_certainty * scam_certainty * competition_certainty

      %{
        opportunity: opp,
        id: opp.id,
        quote: q,
        plan: plan,
        tax_rate: fees.tax,
        broker_rate: fees.broker,
        margin_pct: q.margin_pct,
        daily_volume: daily_volume,
        profit_day: plan.profit_day,
        cost: plan.cost,
        certainty: certainty,
        score: plan.profit_day * certainty,
        shield: shield,
        history: stats,
        age_min: age_min,
        breakdown: %{
          data_certainty: data_certainty,
          scam_certainty: scam_certainty,
          competition_certainty: competition_certainty
        }
      }
    else
      _ -> nil
    end
  end

  @doc """
  Comisiones del piloto en una estación NPC: sales tax por Accounting y broker por Broker
  Relations y standings (sin modificar) con la corporación dueña y su facción.
  """
  @spec fees(pos_integer(), map()) :: %{tax: float(), broker: float()}
  def fees(location_id, p) do
    {corp_id, faction_id} = owner(location_id)
    standings = Map.get(p, :standings) || %{}

    broker =
      Fees.broker_fee_npc(
        p.broker_relations,
        Map.get(standings, faction_id, 0),
        Map.get(standings, corp_id, 0)
      )

    %{tax: Fees.sales_tax(p.accounting), broker: max(broker, 0.0)}
  end

  defp owner(location_id) do
    with %{owner_id: corp_id} <- Sde.station(location_id),
         %{faction_id: faction_id} <- Sde.corporation(corp_id) do
      {corp_id, faction_id}
    else
      _ -> {nil, nil}
    end
  end

  # Anti-scam (RF-4.8) sobre la mejor compra que se va a superar: una compra muy por encima
  # de la mediana es justamente la firma del margin trading scam.
  defp shield(opp, q, stats, own_ids, now) do
    {_price, _vol, _id, issued, min_volume} =
      Enum.find(opp.bids, &(not MapSet.member?(own_ids, elem(&1, 2))))

    Shield.evaluate(%{
      bid: q.best_bid,
      ask: q.best_ask,
      roi: q.margin_pct,
      bid_min_volume: min_volume,
      bid_issued: issued && DateTime.from_unix!(issued),
      dest_stats: stats,
      origin_stats: stats,
      global_average: Prices.average(opp.type_id),
      now: now
    })
  end

  defp keep?(row, p) do
    row.margin_pct >= p.min_margin and row.daily_volume >= p.min_daily_volume and
      row.profit_day >= p.min_profit_day and Query.shield_visible?(row.shield.status, p.shield)
  end

  defp matches?(_opp, ""), do: true

  defp matches?(opp, search),
    do: Search.matches?(StationOpportunity.search_text(opp), search)

  defp sort(rows, :margin), do: Enum.sort_by(rows, &{-&1.margin_pct, -&1.score})
  defp sort(rows, :volume), do: Enum.sort_by(rows, &{-&1.daily_volume, -&1.score})
  defp sort(rows, :age), do: Enum.sort_by(rows, &{&1.age_min, -&1.score})
  defp sort(rows, :profit_day), do: Enum.sort_by(rows, &{-&1.profit_day, -&1.score})
  defp sort(rows, _score), do: Enum.sort_by(rows, &{-&1.score, -&1.profit_day})
end
