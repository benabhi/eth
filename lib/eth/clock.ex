defmodule Eth.Clock do
  @moduledoc """
  Reloj inyectable para toda la lógica temporal (RNF-7.5).

  En producción delega en `DateTime.utc_now/0`. En tests se puede fijar la hora con
  `Eth.Clock.freeze/1` (por proceso), sin tocar el reloj de otros tests.
  """

  @key {__MODULE__, :frozen}

  @doc "Hora actual en UTC (o la fijada para el proceso actual)."
  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Process.get(@key) do
      nil -> DateTime.utc_now()
      %DateTime{} = frozen -> frozen
    end
  end

  @doc "Milisegundos desde `now` hasta `datetime` (0 si ya pasó)."
  @spec ms_until(DateTime.t()) :: non_neg_integer()
  def ms_until(%DateTime{} = datetime) do
    max(DateTime.diff(datetime, utc_now(), :millisecond), 0)
  end

  @doc "Fija la hora para el proceso actual (solo tests)."
  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{} = datetime) do
    Process.put(@key, datetime)
    :ok
  end
end
