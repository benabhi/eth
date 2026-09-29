defmodule EthWeb.HunterParams do
  @moduledoc """
  Traducción entre los filtros del Cazador (strings de formulario o de la URL) y los
  parámetros de `Eth.Engine.Query` (RF-6.4).

  Los montos aceptan sufijos estilo EVE: `5M`, `1.5B`, `250k` (y coma decimal).
  Un campo vacío significa "sin límite".
  """

  alias Eth.Engine.Query

  @fields ~w(search route_mode max_jumps min_profit min_roi capital cargo_m3 accounting sort)

  @doc "Campos del formulario."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "Valores del formulario por defecto (strings), a partir de los defaults del motor."
  @spec form_defaults() :: %{String.t() => String.t()}
  def form_defaults do
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
      "sort" => Atom.to_string(d.sort)
    }
  end

  @doc "Parámetros de la consulta a partir de strings (valores inválidos se ignoran)."
  @spec to_query(map()) :: map()
  def to_query(form) do
    form = Map.merge(form_defaults(), Map.take(form, @fields))

    %{
      search: String.trim(form["search"]),
      route_mode: if(form["route_mode"] == "shortest", do: :shortest, else: :secure),
      max_jumps: parse_integer(form["max_jumps"]),
      min_profit: parse_isk(form["min_profit"]) || 0,
      min_roi: (parse_number(form["min_roi"]) || 0) / 100,
      capital: parse_isk(form["capital"]),
      cargo_m3: parse_number(form["cargo_m3"]),
      accounting: parse_integer(form["accounting"]) |> clamp_level(),
      sort: parse_sort(form["sort"])
    }
  end

  @doc "Solo los campos que difieren del default (para una URL corta)."
  @spec to_url_params(map()) :: map()
  def to_url_params(form) do
    defaults = form_defaults()

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

  defp parse_sort(value) do
    Enum.find(Query.sorts(), :tvs, &(Atom.to_string(&1) == value))
  end
end
