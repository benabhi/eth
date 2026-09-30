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
  end
end
