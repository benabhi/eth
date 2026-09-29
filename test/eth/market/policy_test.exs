defmodule Eth.Market.PolicyTest do
  use ExUnit.Case, async: true

  alias Eth.Market.Policy

  test "nivel: hubs por configuración y activas por páginas" do
    assert Policy.tier(10_000_002, nil) == :hub
    assert Policy.tier(10_000_016, 12) == :active
    assert Policy.tier(10_000_016, 2) == :rest
    assert Policy.tier(10_000_016, nil) == :rest
  end

  test "tabla de frecuencias de ERS §8.11" do
    for ratio <- [1.0, 0.5, 0.3, 0.15, 0.05], do: assert(Policy.every(:hub, ratio) == 1)

    assert Policy.every(:active, 0.5) == 1
    assert Policy.every(:rest, 0.5) == 1
    assert Policy.every(:active, 0.3) == 1
    assert Policy.every(:rest, 0.3) == 2
    assert Policy.every(:active, 0.15) == 2
    assert Policy.every(:rest, 0.15) == 3
    assert Policy.every(:active, 0.05) == :paused
    assert Policy.every(:rest, 0.05) == :paused
  end

  test "fetch? respeta los ciclos salteados" do
    refute Policy.fetch?(:rest, 0.3, 0)
    assert Policy.fetch?(:rest, 0.3, 1)
    refute Policy.fetch?(:active, 0.05, 99)
    assert Policy.fetch?(:hub, 0.0, 0)
  end
end
