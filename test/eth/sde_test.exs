defmodule Eth.SdeTest do
  use ExUnit.Case, async: true

  alias Eth.Sde

  test "seguridad mostrada con la regla del cliente (ERS §8.1)" do
    assert Sde.security_display(0.945913) == 0.9
    assert Sde.security_display(0.45) == 0.5
    assert Sde.security_display(0.449) == 0.4
    # Ningún sistema con seguridad positiva se muestra como 0.0.
    assert Sde.security_display(0.02) == 0.1
    assert Sde.security_display(-0.02) == -0.0 or Sde.security_display(-0.02) == 0.0
    assert Sde.security_display(-0.78) == -0.8
  end

  test "bandas de seguridad" do
    assert Sde.security_band(0.505) == :highsec
    assert Sde.security_band(0.45) == :highsec
    assert Sde.security_band(0.421) == :lowsec
    assert Sde.security_band(0.02) == :lowsec
    assert Sde.security_band(0.0) == :nullsec
    assert Sde.security_band(-0.5) == :nullsec
  end

  test "colores de la escala del cliente (Anexo B.6)" do
    # 0.95 en binario es 0.9499…: se muestra 0.9 (regla de redondeo al décimo más cercano).
    assert Sde.security_color(0.97) == "#2FEFEF"
    assert Sde.security_color(0.949) == "#48F0C0"
    assert Sde.security_color(0.5) == "#EFEF00"
    assert Sde.security_color(0.02) == "#D73000"
    assert Sde.security_color(-0.4) == "#F00000"
  end

  test "sin datos cargados las consultas devuelven nil" do
    refute Sde.ready?()
    assert Sde.system(30_000_142) == nil
    assert Sde.system_by_name("Jita") == nil
  end
end
