defmodule EthWeb.HunterParamsTest do
  use ExUnit.Case, async: true

  alias EthWeb.{Format, HunterParams}

  test "montos con sufijo estilo EVE" do
    assert HunterParams.parse_isk("5M") == 5_000_000.0
    assert HunterParams.parse_isk("1.5B") == 1_500_000_000.0
    assert HunterParams.parse_isk("1,5b") == 1_500_000_000.0
    assert HunterParams.parse_isk("250k") == 250_000.0
    assert HunterParams.parse_isk(" 38500 ") == 38_500.0
    assert HunterParams.parse_isk("") == nil
    assert HunterParams.parse_isk("mucho") == nil
  end

  test "del formulario a la consulta, con defaults y valores inválidos ignorados" do
    q =
      HunterParams.to_query(%{
        "search" => " jita ",
        "route_mode" => "shortest",
        "min_profit" => "5M",
        "min_roi" => "2,5",
        "capital" => "",
        "cargo_m3" => "abc",
        "accounting" => "9",
        "sort" => "no-existe"
      })

    assert q.search == "jita"
    assert q.route_mode == :shortest
    assert q.min_profit == 5_000_000.0
    assert_in_delta q.min_roi, 0.025, 1.0e-9
    assert q.capital == nil
    assert q.cargo_m3 == nil
    assert q.accounting == 5
    assert q.sort == :tvs
  end

  test "la URL solo lleva lo que difiere del default" do
    form =
      Map.merge(HunterParams.form_defaults(), %{"search" => "helium", "route_mode" => "secure"})

    assert HunterParams.to_url_params(form) == %{"search" => "helium"}
  end

  test "duración de viaje legible" do
    assert Format.travel(20) == "1 min"
    assert Format.travel(1110) == "19 min"
    assert Format.travel(3760) == "1 h 03 min"
  end
end
