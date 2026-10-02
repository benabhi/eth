defmodule Eth.Engine.SkillGainsTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.SkillGains

  # Beneficio de juguete: cada nivel de Accounting suma 100 y cada uno de Broker, 10.
  defp value(p), do: 1_000.0 + p.accounting * 100 + p.broker_relations * 10

  test "ganancia al nivel siguiente y al V, por habilidad" do
    [acc, broker] =
      SkillGains.gains(
        %{accounting: 2, broker_relations: 4},
        [:accounting, :broker_relations],
        &value/1
      )

    assert acc == %{
             skill: :accounting,
             level: 2,
             next: %{level: 3, gain: 100.0},
             max: %{level: 5, gain: 300.0}
           }

    # A un nivel del V: solo el siguiente (que ya es el V).
    assert broker.next == %{level: 5, gain: 10.0}
    assert broker.max == nil
  end

  test "al máximo no hay nada que subir; sin contrato viable no hay comparación" do
    assert [%{next: nil, max: nil}] =
             SkillGains.gains(%{accounting: 5, broker_relations: 0}, [:accounting], &value/1)

    assert SkillGains.gains(%{accounting: 0}, [:accounting], fn _ -> nil end) == []
  end

  test "un nivel con el que el contrato deja de ser viable no se informa" do
    fun = fn p -> if p.accounting == 3, do: 50.0, else: nil end
    assert [%{next: nil, max: nil}] = SkillGains.gains(%{accounting: 3}, [:accounting], fun)
  end
end
