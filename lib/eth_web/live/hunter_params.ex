defmodule EthWeb.HunterParams do
  @moduledoc """
  Traducción entre los filtros del Cazador (strings de formulario o de la URL) y los
  parámetros de `Eth.Engine.Query` (RF-6.4).

  Los montos aceptan sufijos estilo EVE: `5M`, `1.5B`, `250k` (y coma decimal).
  Un campo vacío significa "sin límite".
  """

  alias Eth.Engine.Query

  @fields ~w(search route_mode max_jumps min_profit min_roi capital cargo_m3 accounting shield liquid_only no_structures sort)

  @doc "Campos del formulario."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  Valores del formulario por defecto (strings): los defaults del motor, reemplazados por
  los datos del piloto cuando los hay (`Eth.Characters.Pilot.query_overrides/1`).
  """
  @spec form_defaults(map()) :: %{String.t() => String.t()}
  def form_defaults(pilot \\ %{}) do
    d = Query.defaults()

    %{
      "search" => "",
      "route_mode" => Atom.to_string(d.route_mode),
      "max_jumps" => "",
      "min_profit" => format_isk(d.min_profit),
      "min_roi" => "",
      "capital" => "",
      "cargo_m3" => Integer.to_string(round(d.cargo_m3)),
      "accounting" => Integer.to_string(d.accounting),
      "shield" => Atom.to_string(d.shield),
      "liquid_only" => to_string(d.liquid_only),
      "no_structures" => to_string(d.no_structures),
      "sort" => Atom.to_string(d.sort)
    }
    |> Map.merge(pilot_defaults(pilot))
  end

  defp pilot_defaults(pilot) do
    %{
      "capital" => pilot[:capital] && format_capital(pilot.capital),
      "cargo_m3" => pilot[:cargo_m3] && Integer.to_string(floor(pilot.cargo_m3)),
      "accounting" => pilot[:accounting] && Integer.to_string(pilot.accounting)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Capital para el formulario, redondeado hacia abajo al millón (nunca supera el saldo)."
  @spec format_capital(number()) :: String.t()
  def format_capital(capital) when capital >= 1.0e6,
    do: format_isk(Float.floor(capital / 1.0e6) * 1.0e6)

  def format_capital(capital), do: Integer.to_string(floor(capital))

  @doc "Parámetros de la consulta a partir de strings (valores inválidos se ignoran)."
  @spec to_query(map()) :: map()
  def to_query(form) do
    form = Map.merge(form_defaults(), Map.take(form, @fields))

    %{
      search: String.trim(form["search"]),
      route_mode: parse_route_mode(form["route_mode"]),
      max_jumps: parse_integer(form["max_jumps"]),
      min_profit: parse_isk(form["min_profit"]) || 0,
      min_roi: (parse_number(form["min_roi"]) || 0) / 100,
      capital: parse_isk(form["capital"]),
      cargo_m3: parse_number(form["cargo_m3"]),
      accounting: parse_integer(form["accounting"]) |> clamp_level(),
      shield: parse_shield(form["shield"]),
      liquid_only: form["liquid_only"] == "true",
      no_structures: form["no_structures"] == "true",
      sort: parse_sort(form["sort"])
    }
  end

  @doc "Solo los campos que difieren de los defaults (para una URL corta)."
  @spec to_url_params(map(), map()) :: map()
  def to_url_params(form, defaults \\ form_defaults()) do
    form
    |> Map.take(@fields)
    |> Enum.reject(fn {k, v} -> v == Map.get(defaults, k) end)
    |> Map.new()
  end

  @doc "Monto con sufijo (`5M`, `1.5B`, `250k`) a número; `nil` si está vacío o es inválido."
  @spec parse_isk(String.t() | nil) :: number() | nil
  def parse_isk(nil), do: nil

  def parse_isk(text) do
    text = text |> String.trim() |> String.replace(",", ".") |> String.replace(" ", "")

    case Regex.run(~r/^(\d+(?:\.\d+)?)([kKmMbBtT]?)$/, text) do
      [_, number, suffix] -> parse_number(number) * multiplier(String.downcase(suffix))
      _ -> nil
    end
  end

  @doc "Formato corto de un monto para el formulario (`1000000` → `1M`)."
  @spec format_isk(number()) :: String.t()
  def format_isk(n) when n >= 1.0e9 and rem(trunc(n), 1_000_000_000) == 0,
    do: "#{div(trunc(n), 1_000_000_000)}B"

  def format_isk(n) when n >= 1.0e6 and rem(trunc(n), 1_000_000) == 0,
    do: "#{div(trunc(n), 1_000_000)}M"

  def format_isk(n), do: "#{round(n)}"

  defp multiplier(""), do: 1
  defp multiplier("k"), do: 1_000
  defp multiplier("m"), do: 1_000_000
  defp multiplier("b"), do: 1_000_000_000
  defp multiplier("t"), do: 1_000_000_000_000

  defp parse_number(nil), do: nil

  defp parse_number(text) do
    case Float.parse(text |> String.trim() |> String.replace(",", ".")) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_integer(text) do
    case Integer.parse(String.trim(text || "")) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp clamp_level(nil), do: Query.defaults().accounting
  defp clamp_level(n), do: min(n, 5)

  # Segura por defecto (la seguridad del jugador primero); nunca átomos desde strings.
  defp parse_route_mode("shortest"), do: :shortest
  defp parse_route_mode("evasive"), do: :evasive
  defp parse_route_mode(_secure), do: :secure

  @shield_modes ~w(all hide_scam safe)a

  defp parse_shield(value) do
    Enum.find(@shield_modes, Query.defaults().shield, &(Atom.to_string(&1) == value))
  end

  defp parse_sort(value) do
    Enum.find(Query.sorts(), :tvs, &(Atom.to_string(&1) == value))
  end
end
