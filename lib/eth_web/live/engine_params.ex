defmodule EthWeb.EngineParams do
  @moduledoc """
  Formulario de Ajustes → Motor (RF-9.5): convierte los parámetros de
  `Eth.GameRules.Tunable` entre su valor y el texto del formulario.

  - Porcentajes: se escriben en % (`15` = 0,15).
  - Montos en ISK: admiten sufijos (`150M`, `1.5B`).
  - Vacío: vuelve al valor por defecto.

  Implementa: RF-9.5.
  """

  alias EthWeb.HunterParams

  @doc "Texto del campo para un valor (vacío si no hay valor propio)."
  @spec input(map(), term()) :: String.t()
  def input(_entry, nil), do: ""
  def input(%{kind: :percent}, value), do: number(value * 100)
  def input(%{kind: :isk}, value), do: HunterParams.format_isk(value)
  def input(%{kind: :boolean}, value), do: to_string(value)
  def input(_entry, value), do: number(value)

  @doc "Texto legible del valor por defecto (para el placeholder y la ayuda)."
  @spec display(map(), term()) :: String.t()
  def display(%{kind: :percent}, value), do: "#{number(value * 100)} %"
  def display(%{kind: :isk}, value), do: HunterParams.format_isk(value)
  def display(%{kind: :boolean}, true), do: "sí"
  def display(%{kind: :boolean}, false), do: "no"
  def display(_entry, value), do: number(value)

  @doc """
  Interpreta el texto del formulario: `{:ok, valor}`, `{:ok, nil}` (vacío o igual al
  valor por defecto: vuelve al defecto) o `:error`. El rango lo valida el contexto.
  """
  @spec parse(map(), String.t() | nil, term()) :: {:ok, term()} | :error
  def parse(entry, text, default) do
    case convert(entry, String.trim(text || "")) do
      :blank -> {:ok, nil}
      {:ok, ^default} -> {:ok, nil}
      {:ok, value} -> if same?(value, default), do: {:ok, nil}, else: {:ok, value}
      :error -> :error
    end
  end

  defp convert(_entry, ""), do: :blank
  defp convert(%{kind: :boolean}, "true"), do: {:ok, true}
  defp convert(%{kind: :boolean}, "false"), do: {:ok, false}
  defp convert(%{kind: :boolean}, _text), do: :error

  defp convert(%{kind: :isk}, text) do
    case HunterParams.parse_isk(text) do
      nil -> :error
      value -> {:ok, round(value)}
    end
  end

  defp convert(%{kind: :integer}, text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp convert(%{kind: kind}, text) when kind in [:float, :percent] do
    case Float.parse(String.replace(text, ",", ".")) do
      {n, ""} -> {:ok, if(kind == :percent, do: n / 100, else: n)}
      _ -> :error
    end
  end

  defp same?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-9
  defp same?(a, b), do: a == b

  # Número sin ceros de más: 0.15 → "0.15", 3.0 → "3", 15.000001 → "15".
  defp number(value) when is_integer(value), do: Integer.to_string(value)

  defp number(value) do
    rounded = Float.round(value / 1, 4)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 4])
  end
end
