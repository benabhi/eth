defmodule Eth.Sde.DogmaTest do
  use ExUnit.Case, async: true

  alias Eth.Sde.Dogma
  alias Eth.SdeFixture

  @moduletag :tmp_dir

  @iteron 657
  @expander 1319
  @gallente_hauler 3340

  setup %{tmp_dir: tmp_dir} do
    SdeFixture.write(tmp_dir)

    rows = fn file ->
      tmp_dir |> Path.join(file <> ".jsonl") |> File.stream!() |> Stream.map(&Jason.decode!/1)
    end

    dogma = Dogma.build(rows.("typeDogma"), rows.("dogmaEffects"), rows.("dogmaAttributes"), 38)
    {:ok, dogma: dogma}
  end

  defp fit(modules, skills),
    do: %{ship_type_id: @iteron, base_capacity: 5_800.0, modules: modules, skills: skills}

  test "solo guarda lo que influye en la capacidad", %{dogma: dogma} do
    # La velocidad (37) y el tipo sin relación (34) quedan fuera.
    assert Map.keys(dogma.attributes) |> Enum.sort() == [38, 149, 276, 280, 496]
    assert dogma.types[@iteron] == %{attrs: %{496 => 5.0}, mods: [{:ship, 38, 496, 6}]}
    refute Map.has_key?(dogma.types, 34)
  end

  test "bono del casco por nivel de habilidad y expansores de bodega", %{dogma: dogma} do
    # 5% por nivel de Gallente Hauler: V ⇒ +25 %.
    assert_in_delta Dogma.cargo_capacity(dogma, fit([], %{@gallente_hauler => 5})),
                    7_250.0,
                    1.0e-6

    assert_in_delta Dogma.cargo_capacity(dogma, fit([], %{@gallente_hauler => 0})),
                    5_800.0,
                    1.0e-6

    # Dos Expanded Cargohold II (×1,275 cada uno, sin penalización: capacidad apilable).
    expected = 5_800 * 1.25 * 1.275 * 1.275

    assert_in_delta Dogma.cargo_capacity(
                      dogma,
                      fit([@expander, @expander], %{@gallente_hauler => 5})
                    ),
                    expected,
                    1.0e-6
  end

  test "sin datos de dogma no calcula" do
    assert Dogma.cargo_capacity(nil, fit([], %{})) == nil
  end

  test "penaliza por apilamiento los atributos no apilables" do
    # Atributo 37 no apilable con tres módulos de +10 %: 1 + 0,1·(1 + 0,869 + 0,571).
    dogma = %{
      attributes: %{
        37 => %{default: 0.0, stackable: false},
        20 => %{default: 0.0, stackable: true}
      },
      types: %{
        1 => %{attrs: %{37 => 100.0}, mods: []},
        2 => %{attrs: %{20 => 10.0}, mods: [{:ship, 37, 20, 6}]}
      }
    }

    fit = %{ship_type_id: 1, base_capacity: 0.0, modules: [2, 2, 2], skills: %{}}
    weights = Enum.map(0..2, &:math.exp(-:math.pow(&1 / 2.67, 2)))
    expected = Enum.reduce(weights, 100.0, &(&2 * (1 + 0.1 * &1)))

    assert_in_delta Dogma.attribute_value(dogma, fit, :ship, 37), expected, 1.0e-9
  end
end
