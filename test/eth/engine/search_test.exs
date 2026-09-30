defmodule Eth.Engine.SearchTest do
  use ExUnit.Case, async: true

  alias Eth.Engine.Search

  test "normaliza sin mayúsculas, acentos ni espacios en los extremos" do
    assert Search.normalize("  Émpéror Family ÁCADEMY ") == "emperor family academy"
  end

  test "arma el texto buscable ignorando campos nulos y sin cruzar campos" do
    text = Search.text(["Tritanium", nil, "Jita IV - Moon 4", "The Forge"])

    assert Search.matches?(text, "trit")
    assert Search.matches?(text, "moon 4")
    assert Search.matches?(text, "")
    # "tanium" + "jita" no calzan como una sola palabra cruzando campos.
    refute Search.matches?(text, "taniumjita")
  end
end
