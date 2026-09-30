defmodule Eth.Engine.GradeTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.Grade

  test "rango del contrato según el TVS" do
    assert Grade.rank(100) == "S"
    assert Grade.rank(90) == "S"
    assert Grade.rank(89) == "A"
    assert Grade.rank(75) == "A"
    assert Grade.rank(50) == "B"
    assert Grade.rank(25) == "C"
    assert Grade.rank(24) == "D"
    assert Grade.rank(0) == "D"
  end

  test "peligro según el riesgo de ruta" do
    assert Grade.danger(1.0) == :low
    assert Grade.danger(0.95) == :low
    assert Grade.danger(0.9) == :moderate
    assert Grade.danger(0.7) == :high
    assert Grade.danger(0.5) == :extreme
    assert Enum.map([:low, :moderate, :high, :extreme], &Grade.danger_step/1) == [1, 2, 3, 4]
  end

  test "rango del cazador y progreso al siguiente" do
    assert %{rank: "I", next: "II", progress: +0.0} = Grade.hunter_rank(0)
    assert %{rank: "IV", next: "V", progress: p} = Grade.hunter_rank(7_500_000_000)
    assert_in_delta p, 0.5, 1.0e-9
    assert %{rank: "VII", next: nil, progress: 1.0} = Grade.hunter_rank(80_000_000_000)
  end
end
