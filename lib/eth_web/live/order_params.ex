defmodule EthWeb.OrderParams do
  @moduledoc """
  Traducción entre los filtros de la vista Por órdenes (strings del formulario o de la
  URL) y los parámetros de `Eth.Engine.OrderQuery` (RF-4.1, RF-6.4, RF-6.12).

  Porcentajes como tales (`5` = 5 %); montos con sufijos estilo EVE (`5M`, `1.5B`).
  """

  alias Eth.Engine.OrderQuery
  alias EthWeb.HunterParams

  @fields ~w(search mode route_mode max_days min_margin min_profit capital cargo_m3 accounting broker_relations shield sort)

  @doc "Campos del formulario."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "Valores por defecto (strings), con los datos del piloto si los hay."
  @spec form_defaults(map()) :: %{String.t() => String.t()}
  def form_defaults(pilot \\ %{}) do
    d = OrderQuery.defaults()

    %{
      "search" => "",
      "mode" => "",
      "route_mode" => Atom.to_string(d.route_mode),
      "max_days" => Integer.to_string(d.max_days),
      "min_margin" => Integer.to_string(round(d.min_margin * 100)),
      "min_profit" => HunterParams.format_isk(d.min_profit),
      "capital" => "",
      "cargo_m3" => Integer.to_string(round(d.cargo_m3)),
      "accounting" => Integer.to_string(d.accounting),
      "broker_relations" => Integer.to_string(d.broker_relations),
      "shield" => Atom.to_string(d.shield),
      "sort" => Atom.to_string(d.sort)
    }
    |> Map.merge(pilot_defaults(pilot))
  end

  defp pilot_defaults(pilot) do
    %{
      "capital" => pilot[:capital] && HunterParams.format_capital(pilot.capital),
      "cargo_m3" => pilot[:cargo_m3] && Integer.to_string(floor(pilot.cargo_m3)),
      "accounting" => pilot[:accounting] && Integer.to_string(pilot.accounting),
      "broker_relations" => pilot[:broker_relations] && Integer.to_string(pilot.broker_relations)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Parámetros de la consulta (valores inválidos se ignoran)."
  @spec to_query(map()) :: map()
  def to_query(form) do
    d = OrderQuery.defaults()
    form = Map.merge(form_defaults(), Map.take(form, @fields))

    %{
      search: String.trim(form["search"] || ""),
      mode: pick(form["mode"], [:listing, :buy_order], nil),
      route_mode: pick(form["route_mode"], [:secure, :shortest], d.route_mode),
      max_days: positive(form["max_days"]) || d.max_days,
      min_margin: (number(form["min_margin"]) || d.min_margin * 100) / 100,
      min_profit: HunterParams.parse_isk(form["min_profit"]) || 0,
      capital: HunterParams.parse_isk(form["capital"]),
      cargo_m3: number(form["cargo_m3"]),
      accounting: level(form["accounting"], d.accounting),
      broker_relations: level(form["broker_relations"], d.broker_relations),
      shield: pick(form["shield"], [:hide_scam, :safe, :all], d.shield),
      sort: pick(form["sort"], OrderQuery.sorts(), d.sort)
    }
  end

  @doc "Solo los campos que difieren de los defaults (URL corta)."
  @spec to_url_params(map(), map()) :: map()
  def to_url_params(form, defaults \\ form_defaults()) do
    form
    |> Map.take(@fields)
    |> Enum.reject(fn {k, v} -> v == Map.get(defaults, k) end)
    |> Map.new()
  end

  # Átomo de una lista cerrada (nunca String.to_atom con datos externos).
  defp pick(value, allowed, default),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == value))

  defp level(value, default) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n in 0..5 -> n
      _ -> default
    end
  end

  defp positive(value) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp number(nil), do: nil

  defp number(text) do
    case Float.parse(text |> String.trim() |> String.replace(",", ".")) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end
end
