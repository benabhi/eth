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

    test "con hold, los minutos sin datos repiten el último valor medido" do
      assert UI.spark_hold([nil, 3, nil, nil, 5, nil]) == [nil, 3, 3, 3, 5, 5]
      assert UI.spark_hold([nil, nil]) == [nil, nil]
      assert [_one_line] = [nil, 3, nil, 5] |> UI.spark_hold() |> UI.spark_segments()
    end
  end
end
