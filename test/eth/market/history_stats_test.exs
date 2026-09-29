defmodule Eth.Market.HistoryStatsTest do
  use ExUnit.Case, async: false

  alias Eth.Market.HistoryStats

  @as_of ~D[2026-09-28]

  defp day(offset, average, volume) do
    %{
      "date" => Date.to_iso8601(Date.add(@as_of, -offset)),
      "average" => average,
      "highest" => average,
      "lowest" => average,
      "order_count" => 10,
      "volume" => volume
    }
  end

  describe "last_day/1" do
    # La ventana de downtime en tests está vacía (00:00–00:00): se prueba con la real.
    setup do
      previous = Application.get_env(:eth, Eth.GameRules)

      Application.put_env(
        :eth,
        Eth.GameRules,
        Keyword.put(previous, :downtime_window_utc, {~T[10:59:00], ~T[11:15:00]})
      )

      on_exit(fn -> Application.put_env(:eth, Eth.GameRules, previous) end)
    end

    test "antes del fin del downtime el último día publicado es anteayer" do
      assert HistoryStats.last_day(~U[2026-09-29 11:00:00Z]) == ~D[2026-09-27]
      assert HistoryStats.last_day(~U[2026-09-29 11:15:00Z]) == ~D[2026-09-28]
      assert HistoryStats.last_day(~U[2026-09-29 23:59:00Z]) == ~D[2026-09-28]
    end

    test "las estadísticas vencen cuando ESI publica un día nuevo" do
      stats = HistoryStats.compute([], @as_of)
      assert HistoryStats.fresh?(stats, ~U[2026-09-30 11:00:00Z])
      refute HistoryStats.fresh?(stats, ~U[2026-09-30 11:20:00Z])
    end
  end

  test "calcula mediana, promedio ponderado, volumen y días con operaciones" do
    entries = [
      day(0, 100.0, 10),
      day(1, 110.0, 30),
      day(2, 90.0, 20),
      # Fuera de la ventana de 7 días, dentro de la de 30.
      day(10, 1_000.0, 5),
      # Fuera de las dos ventanas.
      day(45, 5.0, 1_000)
    ]

    stats = HistoryStats.compute(entries, @as_of)

    assert stats.as_of == @as_of
    assert stats.median_7d == 100.0
    assert stats.median_30d == 105.0
    assert_in_delta stats.avg_7d, (1_000 + 3_300 + 1_800) / 60, 1.0e-9
    assert_in_delta stats.volume_avg_7d, 60 / 7, 1.0e-9
    assert_in_delta stats.volume_avg_30d, 65 / 30, 1.0e-9
    assert stats.days_traded_30d == 4
    assert length(stats.daily_avg) == 30
    assert List.last(stats.daily_avg) == 100.0
    assert Enum.at(stats.daily_avg, 19) == 1_000.0
    assert Enum.at(stats.daily_volume, 18) == 0
  end

  test "un día con volumen 0 no cuenta como operado" do
    stats = HistoryStats.compute([day(0, 100.0, 0)], @as_of)
    assert stats.days_traded_30d == 0
    assert stats.median_7d == nil
    assert stats.avg_30d == nil
    assert stats.stddev_30d == nil
  end

  test "mediana de una cantidad par e impar de valores" do
    assert HistoryStats.median([3, 1, 2]) == 2.0
    assert HistoryStats.median([4, 1, 3, 2]) == 2.5
    assert HistoryStats.median([]) == nil
  end
end
