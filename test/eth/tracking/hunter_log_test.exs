defmodule Eth.Tracking.HunterLogTest do
  use ExUnit.Case, async: true

  alias Eth.Tracking.HunterLog

  @now ~U[2026-09-30 12:00:00Z]

  # Viaje reconciliado que cerró `days_ago` días antes de @now y duró `hours` horas.
  defp run(id, profit, days_ago, opts \\ []) do
    closed = DateTime.add(@now, -days_ago * 86_400, :second)
    hours = Keyword.get(opts, :hours, 1)

    %{
      id: id,
      realized_profit: profit,
      predicted_profit: Keyword.get(opts, :predicted, profit),
      started_at: DateTime.add(closed, -hours * 3600, :second),
      closed_at: closed,
      plan: %{"type_name" => "Tipo #{id}", "tvs" => Keyword.get(opts, :tvs, 60)}
    }
  end

  test "sin viajes reconciliados todo está en cero y los hitos pendientes" do
    unreconciled = %{run(1, 1.0e6, 0) | realized_profit: nil}
    log = HunterLog.build([unreconciled], @now)

    assert log.all.contracts == 0
    assert log.all.reward == 0.0
    assert log.all.isk_per_hour == nil
    assert log.streak == 0
    assert log.rank.rank == "I"
    assert Enum.all?(log.milestones, &is_nil(&1.achieved_at))
  end

  test "estadísticas por período, ISK/h, precisión y mejor contrato" do
    runs = [
      run(1, 200_000_000.0, 0, hours: 2, predicted: 250_000_000.0),
      run(2, 100_000_000.0, 3, hours: 1, predicted: 100_000_000.0),
      run(3, 50_000_000.0, 20, hours: 1)
    ]

    log = HunterLog.build(runs, @now)

    assert log.week.contracts == 2
    assert log.month.contracts == 3
    assert log.all.reward == 350_000_000.0
    # 350M en 4 horas.
    assert_in_delta log.all.isk_per_hour, 87_500_000.0, 1.0
    # Precisiones 0,8 · 1 · 1.
    assert_in_delta log.all.accuracy, (0.8 + 1 + 1) / 3, 1.0e-9
    assert log.all.best.id == 1
  end

  test "la racha cuenta días seguidos que terminan hoy o ayer" do
    assert HunterLog.streak(
             HunterLog.reconciled([run(1, 1.0, 1), run(2, 1.0, 2), run(3, 1.0, 4)]),
             @now
           ) ==
             2

    assert HunterLog.streak(HunterLog.reconciled([run(1, 1.0, 2)]), @now) == 0
  end

  test "cada hito se marca en el viaje que cruza el umbral" do
    runs = [
      run(1, 60_000_000.0, 3),
      run(2, 60_000_000.0, 2, tvs: 95),
      run(3, 900_000_000.0, 1)
    ]

    milestones = Map.new(HunterLog.milestones(runs), &{&1.key, &1})

    assert milestones["first"].run.id == 1
    # 60M + 60M = 120M cruza los 100M en el segundo viaje.
    assert milestones["reward:100000000"].run.id == 2
    assert milestones["reward:1000000000"].run.id == 3
    assert milestones["s:1"].run.id == 2
    assert milestones["streak:3"].run.id == 3

    pending = milestones["reward:10000000000"]
    assert pending.achieved_at == nil
    assert_in_delta pending.progress, 1_020_000_000 / 10_000_000_000, 1.0e-9

    assert HunterLog.achieved_keys(HunterLog.milestones(runs)) |> MapSet.member?("first")
  end
end
