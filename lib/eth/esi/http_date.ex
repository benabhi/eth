defmodule Eth.Esi.HttpDate do
  @moduledoc """
  Parser de fechas HTTP (RFC 7231, formato IMF-fixdate) usadas por ESI en `Expires` y
  `Last-Modified`, p. ej. `"Tue, 29 Sep 2026 00:02:18 GMT"`.
  """

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
          |> Enum.with_index(1)
          |> Map.new()

  @doc "Convierte una fecha HTTP a `DateTime` UTC; `nil` si no es válida."
  @spec parse(String.t() | nil) :: DateTime.t() | nil
  def parse(nil), do: nil

  def parse(value) when is_binary(value) do
    with [_, day, month, year, time] <-
           Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value),
         {:ok, month} <- Map.fetch(@months, month),
         {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end
end
