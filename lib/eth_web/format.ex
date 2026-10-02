defmodule EthWeb.Format do
  @moduledoc """
  Formato de números, tamaños y tiempos para la UI (RNF-5.5, RNF-5.6).

  Números en estilo EVE (coma de miles, punto decimal) y abreviaturas K/M/B/T.
  """

  @doc """
  Abrevia un número: `1_234` → `"1.2k"`, `404_647` → `"405k"`, `5_020_000_000` → `"5.02B"`.
  """
  @spec compact(number() | nil) :: String.t()
  def compact(nil), do: "—"

  def compact(n) when is_number(n) do
    abs = abs(n)

    cond do
      abs >= 1.0e12 -> scaled(n, 1.0e12, "T")
      abs >= 1.0e9 -> scaled(n, 1.0e9, "B")
      abs >= 1.0e6 -> scaled(n, 1.0e6, "M")
      abs >= 1.0e3 -> scaled(n, 1.0e3, "k")
      true -> integer(round(n))
    end
  end

  # 3 cifras significativas: 1.23M, 12.3M, 123M
  defp scaled(n, unit, suffix) do
    value = n / unit

    decimals =
      cond do
        abs(value) >= 100 -> 0
        abs(value) >= 10 -> 1
        true -> 2
      end

    (value |> Float.round(decimals) |> :erlang.float_to_binary(decimals: decimals)) <> suffix
  end

  @doc "Entero con coma de miles: `404647` → `\"404,647\"`."
  @spec integer(integer() | nil) :: String.t()
  def integer(nil), do: "—"

  def integer(n) when is_integer(n) do
    sign = if n < 0, do: "-", else: ""

    digits =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    sign <> digits
  end

  @doc "Bytes en MB o GB: `77_700_000` → `\"74.1 MB\"`."
  @spec bytes(non_neg_integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(b) when b >= 1_073_741_824, do: "#{Float.round(b / 1_073_741_824, 2)} GB"
  def bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  @doc "Cuenta regresiva `mm:ss` (o `h:mm:ss`) hasta `datetime`; `00:00` si ya pasó."
  @spec countdown(DateTime.t() | nil, DateTime.t()) :: String.t()
  def countdown(nil, _now), do: "—"

  def countdown(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(datetime, now, :second), 0)
    duration(seconds)
  end

  @doc "Segundos como `mm:ss` o `h:mm:ss`."
  @spec duration(non_neg_integer()) :: String.t()
  def duration(seconds) when seconds >= 3600 do
    "#{div(seconds, 3600)}:#{pad(div(rem(seconds, 3600), 60))}:#{pad(rem(seconds, 60))}"
  end

  def duration(seconds), do: "#{pad(div(seconds, 60))}:#{pad(rem(seconds, 60))}"

  @doc "Duración de viaje legible: `18 min`, `1 h 02 min` (redondeo al minuto)."
  @spec travel(non_neg_integer()) :: String.t()
  def travel(seconds) do
    minutes = round(seconds / 60)

    if minutes < 60,
      do: "#{max(minutes, 1)} min",
      else: "#{div(minutes, 60)} h #{pad(rem(minutes, 60))} min"
  end

  @doc """
  Tiempo de un contrato en el tablón (RF-6.14): `{minutos, cota}` de
  `Eth.Engine.board_age/3` → `"12 min"`, `"3 h"`, `"2 d"`; con cota (ya estaba al
  arrancar la aplicación), `"≥ 3 h"`.
  """
  @spec board_age({non_neg_integer(), boolean()} | nil) :: String.t()
  def board_age(nil), do: "—"
  def board_age({minutes, _lower?}) when minutes < 1, do: "< 1 min"

  def board_age({minutes, lower?}) do
    text =
      cond do
        minutes < 60 -> "#{minutes} min"
        minutes < 1440 -> "#{div(minutes, 60)} h"
        true -> "#{div(minutes, 1440)} d"
      end

    if lower?, do: "≥ " <> text, else: text
  end

  @doc "Antigüedad relativa en español: `hace 4 s`, `hace 9 min`, `hace 2 h`."
  @spec ago(DateTime.t() | nil, DateTime.t()) :: String.t()
  def ago(nil, _now), do: "—"

  def ago(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      seconds < 60 -> "hace #{seconds} s"
      seconds < 3600 -> "hace #{div(seconds, 60)} min"
      seconds < 86_400 -> "hace #{div(seconds, 3600)} h"
      true -> "hace #{div(seconds, 86_400)} d"
    end
  end

  @doc "Hora UTC `HH:MM:SS` (hora EVE)."
  @spec eve_time(DateTime.t() | nil) :: String.t()
  def eve_time(nil), do: "—"
  def eve_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
