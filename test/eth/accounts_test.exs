defmodule Eth.AccountsTest do
  use Eth.DataCase, async: false

  alias Eth.{Accounts, GameRules, Repo}
  alias Eth.Accounts.Operator
  alias Eth.GameRules.Overrides

  setup do
    start_supervised!(Overrides)
    :ok
  end

  test "hay un solo operador y se crea al primer uso" do
    operator = Accounts.operator()
    assert operator.name == "Operador"
    assert Accounts.operator().id == operator.id
  end

  test "un override reemplaza la regla sin recompilar y se puede restablecer" do
    assert GameRules.get(:sales_tax_base) == 0.075

    assert :ok = Accounts.put_game_rule(:sales_tax_base, 0.08)
    assert GameRules.get(:sales_tax_base) == 0.08
    assert GameRules.default(:sales_tax_base) == 0.075
    assert Accounts.game_rule_overrides() == %{sales_tax_base: 0.08}

    # Persiste: al reiniciar el dueño de la tabla se vuelve a cargar.
    stop_supervised!(Overrides)
    start_supervised!(Overrides)
    assert GameRules.get(:sales_tax_base) == 0.08

    assert :ok = Accounts.reset_game_rule(:sales_tax_base)
    assert GameRules.get(:sales_tax_base) == 0.075
  end

  test "solo acepta reglas conocidas y valores entre 0 y 1" do
    assert {:error, :unknown_rule} = Accounts.put_game_rule(:jump_seconds, 0.5)
    assert {:error, :invalid_value} = Accounts.put_game_rule(:sales_tax_base, 1.5)
    assert {:error, :invalid_value} = Accounts.put_game_rule(:sales_tax_base, -0.1)
    assert {:error, :unknown_rule} = Accounts.reset_game_rule(:nope)
  end

  test "ignora claves guardadas que no admiten override" do
    operator = Accounts.operator()

    operator
    |> Operator.settings_changeset(%{
      "game_rules" => %{"jump_seconds" => 1, "x" => 2}
    })
    |> Repo.update!()

    assert Accounts.game_rule_overrides() == %{}
  end
end
