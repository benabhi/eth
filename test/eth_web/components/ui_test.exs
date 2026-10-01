defmodule EthWeb.UITest do
  use ExUnit.Case, async: true

  alias EthWeb.UI

  describe "sparkline (RF-8.9)" do
    test "los minutos sin datos cortan la línea en tramos" do
      assert [first, second] = UI.spark_segments([1, 2, nil, 3, 4])
      assert length(String.split(first)) == 2
      assert length(String.split(second)) == 2
    end

    test "sin datos no hay línea; un valor aislado es un trazo corto" do
      assert UI.spark_segments([nil, nil]) == []
      assert [segment] = UI.spark_segments([nil, 5, nil])
      assert length(String.split(segment)) == 2
    end

    test "la escala arranca en cero: valores parecidos no ocupan todo el alto" do
      # 120 / 1 de paso; 6 de 8 queda a 3/4 del alto, no abajo de todo.
      assert ["0.0,1.0 120.0,7.5"] = UI.spark_segments([8, 6])
      assert ["0.0,27.0 120.0,27.0"] = UI.spark_segments([0, 0])
    end

    test "los tramos se unen por encima de los minutos sin datos" do
      assert UI.spark_bridges([1, 2, nil, nil, 3]) == ["30.0,9.7 120.0,1.0"]
      assert UI.spark_bridges([nil, 5, nil]) == []
      assert UI.spark_bridges([nil, nil]) == []
    end
  end
end
