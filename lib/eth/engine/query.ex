defmodule Eth.Engine.Query do
  @moduledoc """
  Personalización en tiempo de consulta (RF-4.14, RF-6.4): sobre las oportunidades
  universales aplica impuestos del piloto, capital, bodega, modo de ruta, triángulo
  (piloto → origen → destino), tiempo, ISK/h, liquidez, anti-scam, Certeza y TVS;
  después filtra y ordena.

  Solo se vuelve a recorrer el libro si cambia el impuesto o hay límites de capital o
  bodega; si no, se reutiliza el cálculo universal.

  El anti-scam y la liquidez se calculan acá y no en la evaluación universal: leen las
  estadísticas de historial de ETS en cada consulta, así el historial que va llegando se
  refleja sin volver a evaluar todo el universo.

  Implementa: RF-2.8, RF-4.6, RF-4.7, RF-4.8, RF-4.12, RF-4.14, RF-6.2, RF-6.4.
  """

  alias Eth.Engine.{Book, Fees, Liquidity, Opportunity, RouteRisk, Score, Search, Shield}
  alias Eth.{GameRules, Routing}
  alias Eth.Market.{History, Prices, StructureManager}

  @sorts [:tvs, :profit, :isk_per_hour, :roi, :jumps, :cost, :age]

  @type params :: %{
          optional(:accounting) => 0..5,
          optional(:capital) => number() | nil,
          optional(:cargo_m3) => number() | nil,
          optional(:route_mode) => :shortest | :secure | :evasive,
          optional(:base_system_id) => pos_integer(),
          optional(:ship_class) => atom(),
          optional(:max_jumps) => pos_integer() | nil,
          optional(:min_profit) => number(),
          optional(:min_roi) => number(),
          optional(:shield) => :all | :hide_scam | :safe,
          optional(:liquid_only) => boolean(),
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
      # La seguridad del jugador primero: los SCAM se ocultan salvo que se pida verlos.
      shield: :hide_scam,
      liquid_only: false,
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
    p = defaults() |> Map.merge(params) |> with_route_context()
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
    p = with_route_context(p)

    with [_ | _] = route <- path(opp.origin.system_id, opp.destination.system_id, p),
         [_ | _] = to_origin_path <- path(p.base_system_id, opp.origin.system_id, p),
         jumps = length(route) - 1,
         to_origin = length(to_origin_path) - 1,
         result = recompute(opp, p),
         true <- result.quantity > 0 and result.profit >= p.min_profit,
         age_min = DateTime.diff(now, opp.last_modified, :second) / 60,
         data_certainty when data_certainty > 0 <- Score.data_certainty(age_min) do
      stops = if opp.origin.location_id == opp.destination.location_id, do: 1, else: 2
      seconds = Score.travel_seconds(to_origin + jumps, stops, p.ship_class)
      isk_per_hour = Score.isk_per_hour(result.profit, seconds)
      roi = result.profit / result.cost
      order_certainty = Score.order_certainty(seconds / 60)
      dest_stats = History.stats(opp.destination.region_id, opp.type_id)
      origin_stats = History.stats(opp.origin.region_id, opp.type_id)
      liquidity = Liquidity.index(dest_stats, result.quantity)
      shield = shield(opp, result, roi, dest_stats, origin_stats, now)

      utility =
        Score.utility(%{
          isk_per_hour: isk_per_hour,
          profit: result.profit,
          roi: roi,
          liquidity: liquidity
        })

      {access_certainty, access} = access(opp, p)
      scam_certainty = Shield.certainty(shield.status)
      route_certainty = route_certainty(to_origin_path, route, result.cost, p)

      certainty =
        order_certainty * data_certainty * scam_certainty * access_certainty * route_certainty

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
        # Órdenes consumidas por la cantidad personalizada (no la universal).
        asks_used: result.asks_used,
        bids_used: result.bids_used,
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
        shield: shield,
        illiquid: Liquidity.illiquid?(dest_stats),
        history: %{destination: dest_stats, origin: origin_stats},
        to_origin_path: to_origin_path,
        route_path: route,
        route_alerts: route_alerts(to_origin_path ++ route, p.risk),
        access: access,
        breakdown: %{
          route_certainty: route_certainty,
          liquidity: liquidity,
          order_certainty: order_certainty,
          data_certainty: data_certainty,
          scam_certainty: scam_certainty,
          access_certainty: access_certainty
        }
      }
    else
      _ -> nil
    end
  end

  # Anti-scam sobre las órdenes que consume la cantidad personalizada (RF-4.8).
  defp shield(opp, result, roi, dest_stats, origin_stats, now) do
    Shield.evaluate(%{
      bid: result.bids_used |> Enum.map(&elem(&1, 0)) |> Enum.max(),
      ask: result.asks_used |> Enum.map(&elem(&1, 0)) |> Enum.min(),
      roi: roi,
      bid_min_volume: result.bids_used |> Enum.map(&elem(&1, 2)) |> Enum.max(),
      bid_issued: opp.bid_issued,
      dest_stats: dest_stats,
      origin_stats: origin_stats,
      global_average: Prices.average(opp.type_id),
      now: now
    })
  end

  # Certeza de acceso (ERS §8.9, AS-8): producto de origen y destino según el acceso del
  # personaje activo a cada estructura (NPC = 1).
  defp access(opp, p) do
    rules = GameRules.get(:access_certainty)
    character_id = Map.get(p, :character_id)
    origin = location_access(opp.origin, character_id)
    destination = location_access(opp.destination, character_id)

    factor =
      if opp.origin.location_id == opp.destination.location_id,
        do: access_factor(origin, rules),
        else: access_factor(origin, rules) * access_factor(destination, rules)

    {factor, %{origin: origin, destination: destination}}
  end

  # Acceso a una ubicación: :npc, :public, :private_ok, :private_unverified o :forbidden.
  defp location_access(%{structure: false}, _character_id), do: :npc

  defp location_access(%{location_id: id}, character_id) do
    case StructureManager.access(id) do
      %{access: %{^character_id => "forbidden"}} -> :forbidden
      %{public: false, access: %{^character_id => "ok"}} -> :private_ok
      %{public: false} -> :private_unverified
      # Pública, o no registrada pero con órdenes en la región (solo las públicas las tienen).
      _public -> :public
    end
  end

  defp access_factor(:npc, _rules), do: 1.0
  defp access_factor(:public, rules), do: rules.public
  defp access_factor(:private_ok, rules), do: rules.private_verified
  defp access_factor(_unverified_or_forbidden, rules), do: rules.unverified

  # Caminos del triángulo (RF-2.8): Rápida y Segura desde la matriz; Evasiva evita las
  # alertas del radar sobre la restricción de Rápida (RF-2.5).
  # Sistemas a evitar (RF-2.5): si el camino los cruza (salvo origen y destino), se busca
  # otro que no los atraviese.
  defp path(from, to, p) do
    route = raw_path(from, to, p)

    if route && Enum.any?(interior(route), &MapSet.member?(p.avoid, &1)) do
      mode = if p.route_mode == :secure, do: :secure, else: :shortest
      Routing.path(from, to, mode, MapSet.to_list(p.avoid))
    else
      route
    end
  end

  defp raw_path(from, to, %{route_mode: :evasive, risk: risk}),
    do: Routing.evasive_path(from, to, :shortest, &threat(risk, &1))

  defp raw_path(from, to, p), do: Routing.matrix_path(from, to, p.route_mode)

  defp interior([_from | rest]), do: Enum.drop(rest, -1)
  defp interior([]), do: []

  # Contexto de ruta leído una vez por consulta: radar y sistemas a evitar.
  defp with_route_context(p) do
    p
    |> Map.put_new_lazy(:risk, &RouteRisk.context/0)
    |> Map.put_new_lazy(:avoid, fn -> MapSet.new(GameRules.get(:avoid_system_ids, [])) end)
  end

  defp threat(risk, system_id) do
    case risk.alerts do
      %{^system_id => %{threat: threat}} -> threat
      _ -> 0.0
    end
  end

  # Ida vacía hasta el origen y viaje cargado hasta el destino (sin contar dos veces el
  # sistema de origen).
  defp route_certainty(to_origin_path, [_origin | loaded], cargo_value, p) do
    RouteRisk.certainty(to_origin_path, p.ship_class, 0, p.risk) *
      RouteRisk.certainty(loaded, p.ship_class, cargo_value, p.risk)
  end

  # Alertas del radar en el camino: cantidad y la más grave (para la insignia).
  defp route_alerts(systems, risk) do
    alerts = systems |> Enum.uniq() |> Enum.map(&risk.alerts[&1]) |> Enum.reject(&is_nil/1)
    %{count: length(alerts), worst: Enum.max_by(alerts, & &1.threat, fn -> nil end)}
  end

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
        avg_sell: opp.avg_sell,
        asks_used: opp.asks,
        bids_used: opp.bids
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
    row.roi >= p.min_roi and (is_nil(p.max_jumps) or row.total_jumps <= p.max_jumps) and
      shield_visible?(row.shield.status, p.shield) and not (p.liquid_only and row.illiquid)
  end

  @doc false
  # Filtro anti-scam (RF-6.4): todo, sin SCAM (por defecto) o solo sin alertas.
  @spec shield_visible?(Shield.status(), :all | :hide_scam | :safe) :: boolean()
  def shield_visible?(_status, :all), do: true
  def shield_visible?(status, :hide_scam), do: status != :scam
  def shield_visible?(status, :safe), do: status in [:ok, :no_history]

  defp matches?(_opp, ""), do: true
  defp matches?(opp, search), do: Search.matches?(Opportunity.search_text(opp), search)

  @doc false
  # Sin mayúsculas ni acentos (RF-6.4).
  @spec normalize(String.t()) :: String.t()
  defdelegate normalize(text), to: Search

  defp sort(rows, :jumps), do: Enum.sort_by(rows, &{&1.total_jumps, -&1.tvs})
  defp sort(rows, :cost), do: Enum.sort_by(rows, &{-&1.cost, -&1.tvs})
  defp sort(rows, :age), do: Enum.sort_by(rows, &{&1.age_min, -&1.tvs})
  defp sort(rows, field), do: Enum.sort_by(rows, &{-Map.fetch!(&1, field), -&1.profit})
end
