defmodule EthWeb.StationParams do
  @moduledoc """
  Traducción entre los filtros de la vista Estación (strings de formulario o de la URL) y
  los parámetros de `Eth.Engine.StationQuery` (RF-4.16, RF-6.4, RF-6.12).

  Los porcentajes se escriben como tales (`5` = 5 %); los montos aceptan sufijos estilo
  EVE (`5M`, `1.5B`). Un campo vacío significa "sin límite" o el valor por defecto.
  """

  alias Eth.Engine.StationQuery
  alias EthWeb.HunterParams

  @fields ~w(search location_id min_margin min_daily_volume capital accounting broker_relations shield no_structures sort)

  @doc "Campos del formulario."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "Valores por defecto (strings), con los datos del piloto si los hay."
  @spec form_defaults(map()) :: %{String.t() => String.t()}
  def form_defaults(pilot \\ %{}) do
    d = StationQuery.defaults()

    %{
      "search" => "",
      "location_id" => "",
      "min_margin" => format_number(d.min_margin * 100),
      "min_daily_volume" => format_number(d.min_daily_volume),
      "capital" => "",
      "accounting" => Integer.to_string(d.accounting),
      "broker_relations" => Integer.to_string(d.broker_relations),
      "shield" => Atom.to_string(d.shield),
      "no_structures" => to_string(d.no_structures),
      "sort" => Atom.to_string(d.sort)
    }
    |> Map.merge(pilot_defaults(pilot))
  end

  defp pilot_defaults(pilot) do
    %{
      "capital" => pilot[:capital] && HunterParams.format_capital(pilot.capital),
      "accounting" => pilot[:accounting] && Integer.to_string(pilot.accounting),
      "broker_relations" => pilot[:broker_relations] && Integer.to_string(pilot.broker_relations)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Parámetros de la consulta a partir de strings (valores inválidos se ignoran)."
  @spec to_query(map()) :: map()
  def to_query(form) do
    defaults = StationQuery.defaults()
    form = Map.merge(form_defaults(), Map.take(form, @fields))

    %{
      search: String.trim(form["search"] || ""),
      location_id: parse_location(form["location_id"]),
      min_margin: (parse_number(form["min_margin"]) || defaults.min_margin * 100) / 100,
      min_daily_volume: parse_number(form["min_daily_volume"]) || 0,
      capital: HunterParams.parse_isk(form["capital"]),
      accounting: level(form["accounting"], defaults.accounting),
      broker_relations: level(form["broker_relations"], defaults.broker_relations),
      shield: parse_atom(form["shield"], [:hide_scam, :safe, :all], defaults.shield),
      no_structures: form["no_structures"] == "true",
      sort: parse_atom(form["sort"], StationQuery.sorts(), defaults.sort)
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

  # Solo lugares de station trading: hubs y estructuras con broker propio (nunca un ID
  # arbitrario de la URL).
  defp parse_location(value) do
    with text when is_binary(text) and text != "" <- value,
         {id, ""} <- Integer.parse(text),
         true <- List.keymember?(Eth.Engine.publish_locations(), id, 0) do
      id
    else
      _ -> nil
    end
  end

  defp level(value, default) do
    case Integer.parse(String.trim(value || "")) do
      {n, ""} when n in 0..5 -> n
      _ -> default
    end
  end

  defp parse_number(nil), do: nil

  defp parse_number(text) do
    case Float.parse(text |> String.trim() |> String.replace(",", ".")) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  # Átomo de una lista cerrada (nunca String.to_atom con datos externos).
  defp parse_atom(value, allowed, default),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == value))

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)

  defp format_number(n) do
    if abs(n - round(n)) < 1.0e-9,
      do: Integer.to_string(round(n)),
      else: :erlang.float_to_binary(n, [:short])
  end
end
