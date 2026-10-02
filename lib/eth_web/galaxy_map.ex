defmodule EthWeb.GalaxyMap do
  @moduledoc """
  Cálculos de presentación del mapa del Centro de control (RF-8.2): tamaño de cada región
  según sus órdenes, calor del radar por región y por sistema, y el arco de la cuenta
  regresiva. Funciones puras; el dibujo (SVG) vive en `EthWeb.ControlLive`.

  - **Calor de una región:** la amenaza más alta entre sus sistemas en alerta, las kills
    de la ventana y cuántos sistemas están en alerta (`Eth.Threat.hot_systems/0`).
  - **Halo:** crece con la amenaza; sin alertas pero con kills, un halo tenue.

  Implementa: RF-8.2, RF-8.5.
  """

  @typedoc "Calor del radar de una región o un sistema."
  @type heat :: %{threat: float(), kills: non_neg_integer(), alerts: non_neg_integer()}

  @doc """
  Calor por región a partir de los sistemas con kills. `region_of` devuelve la región de
  un sistema (o `nil` si no se conoce).
  """
  @spec region_heat([map()], (pos_integer() -> pos_integer() | nil)) :: %{
          pos_integer() => heat()
        }
  def region_heat(hot, region_of) do
    Enum.reduce(hot, %{}, fn h, acc ->
      case region_of.(h.system_id) do
        nil -> acc
        region_id -> Map.update(acc, region_id, system_heat(h), &merge(&1, system_heat(h)))
      end
    end)
  end

  @doc "Calor de un sistema con kills (la amenaza solo cuenta si hay alerta)."
  @spec system_heat(map()) :: heat()
  def system_heat(h) do
    alert? = Map.get(h, :alert) == true

    %{
      threat: if(alert?, do: Map.get(h, :threat, 0.0) / 1, else: 0.0),
      kills: Map.get(h, :kills, 0),
      alerts: if(alert?, do: 1, else: 0)
    }
  end

  defp merge(a, b),
    do: %{threat: max(a.threat, b.threat), kills: a.kills + b.kills, alerts: a.alerts + b.alerts}

  @doc """
  Radio de una región en el lienzo: entre `min` y `max` según la raíz de sus órdenes
  frente a la región con más (la raíz evita que The Forge tape a todas).
  """
  @spec node_radius(non_neg_integer() | nil, pos_integer(), number(), number()) :: float()
  def node_radius(orders, max_orders, min_r \\ 6, max_r \\ 15)
  def node_radius(nil, _max_orders, min_r, _max_r), do: min_r / 1

  def node_radius(orders, max_orders, min_r, max_r) do
    ratio = :math.sqrt(orders / max(max_orders, 1))
    Float.round(min_r + (max_r - min_r) * min(ratio, 1.0), 1)
  end

  @doc "Radio del halo del radar alrededor de un punto de radio `r` (`nil` sin calor)."
  @spec halo_radius(heat() | nil, number()) :: float() | nil
  def halo_radius(nil, _r), do: nil
  def halo_radius(%{alerts: 0, kills: 0}, _r), do: nil
  def halo_radius(%{alerts: 0}, r), do: Float.round(r + 4.0, 1)
  def halo_radius(%{threat: threat}, r), do: Float.round(r + 6 + 14 * min(threat, 1.0), 1)

  @doc "`stroke-dasharray` de un arco que cubre la fracción `value` de un círculo de radio `r`."
  @spec arc_dash(number(), number()) :: String.t()
  def arc_dash(value, r) do
    circumference = 2 * :math.pi() * r
    filled = circumference * min(max(value, 0.0), 1.0)
    "#{Float.round(filled, 2)} #{Float.round(circumference, 2)}"
  end
end
