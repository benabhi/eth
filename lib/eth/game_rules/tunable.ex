defmodule Eth.GameRules.Tunable do
  @moduledoc """
  Parámetros del motor y del riesgo editables desde Ajustes → Motor (RF-9.5): umbrales
  anti-scam, liquidez y frescura, pesos y referencias del TVS, tiempos por salto, la
  matriz de vulnerabilidad celda por celda y el congelado del tablón.

  Cada parámetro es una **ruta** dentro de la configuración (`[:anti_scam,
  :scam_bid_ratio]`; un entero indexa una tupla, como `[:staleness_minutes, 0]`) con su
  tipo, rango y explicación. Los valores guardados se fusionan con el valor por defecto
  de su clave de primer nivel (`merge/1`) y `Eth.GameRules.Overrides` los publica como
  override de esa clave: los módulos que los usan no cambian.

  Las claves guardadas son cadenas (`"anti_scam.scam_bid_ratio"`) y solo se aceptan las
  de este catálogo (nunca `String.to_atom/1` con datos guardados).

  Implementa: RF-9.5.
  """

  use Gettext, backend: EthWeb.Gettext

  alias Eth.GameRules

  @type kind :: :float | :integer | :percent | :isk | :boolean
  @type entry :: %{
          key: String.t(),
          path: [atom() | non_neg_integer()],
          group: atom(),
          label: String.t(),
          help: String.t(),
          kind: kind(),
          min: number() | nil,
          max: number() | nil
        }

  @ship_classes [
    :freighter,
    :industrial,
    :deep_space_transport,
    :blockade_runner,
    :shuttle,
    :other
  ]
  @threats [:gate_camp, :bubble_camp, :smartbomb_camp, :hauler_gank, :roaming]

  @doc "Grupos en el orden de la pantalla: `[{grupo, título, explicación}]`."
  @spec groups() :: [{atom(), String.t(), String.t()}]
  def groups do
    [
      {:anti_scam, gettext("Anti-scam"),
       gettext("Cuándo un precio se marca como trampa (SCAM) o sospechoso frente a la mediana.")},
      {:liquidity, gettext("Liquidez y frescura"),
       gettext("Qué tan operado tiene que estar un objeto y hasta cuándo sirven los datos.")},
      {:tvs, gettext("TVS"),
       gettext(
         "Cuánto pesa cada factor en el puntaje (los pesos deberían sumar 100 %) y el valor con el que cada uno llega a su máximo."
       )},
      {:travel, gettext("Tiempos de viaje"),
       gettext("Segundos por salto de cada clase de nave: definen el ISK/h y la ETA.")},
      {:vulnerability, gettext("Matriz de vulnerabilidad"),
       gettext(
         "Probabilidad de perder la nave ante cada amenaza, por clase: baja la Certeza de las rutas con esa amenaza."
       )},
      {:board, gettext("Tablón"), gettext("Comportamiento de la grilla.")}
    ]
  end

  @doc "Clases de nave de la matriz de vulnerabilidad (filas)."
  @spec ship_classes() :: [atom()]
  def ship_classes, do: @ship_classes

  @doc "Amenazas de la matriz de vulnerabilidad (columnas)."
  @spec threats() :: [atom()]
  def threats, do: @threats

  @doc "Lista completa de parámetros editables."
  @spec entries() :: [entry()]
  def entries do
    anti_scam() ++ liquidity() ++ tvs() ++ travel() ++ vulnerability() ++ board()
  end

  @doc "Parámetros de un grupo."
  @spec entries(atom()) :: [entry()]
  def entries(group), do: Enum.filter(entries(), &(&1.group == group))

  @doc "Parámetro por clave (`nil` si no existe)."
  @spec fetch(String.t()) :: entry() | nil
  def fetch(key), do: Enum.find(entries(), &(&1.key == key))

  defp anti_scam do
    [
      e(
        [:anti_scam, :scam_bid_ratio],
        :anti_scam,
        gettext("Compra SCAM (× mediana)"),
        gettext("Una compra a este múltiplo de la mediana o más se marca SCAM."),
        :float,
        1.1,
        50
      ),
      e(
        [:anti_scam, :suspicious_bid_ratio],
        :anti_scam,
        gettext("Compra sospechosa (× mediana)"),
        gettext("Desde este múltiplo de la mediana la compra se marca sospechosa."),
        :float,
        1.0,
        50
      ),
      e(
        [:anti_scam, :global_price_ratio],
        :anti_scam,
        gettext("Precio irreal sin historial (× global)"),
        gettext(
          "Sin historial, una compra a este múltiplo del precio promedio global o más se marca sospechosa."
        ),
        :float,
        1.1,
        100
      ),
      e(
        [:anti_scam, :origin_ask_ratio],
        :anti_scam,
        gettext("Venta en el origen (× mediana)"),
        gettext(
          "Una venta en el origen a este múltiplo de su mediana, junto a una compra inflada, se marca SCAM."
        ),
        :float,
        1.0,
        50
      ),
      e(
        [:anti_scam, :fresh_order_minutes],
        :anti_scam,
        gettext("Orden reciente (minutos)"),
        gettext(
          "Una compra inflada creada hace menos que esto se marca SCAM: es el señuelo típico."
        ),
        :integer,
        1,
        1_440
      ),
      e(
        [:anti_scam, :min_days_traded],
        :anti_scam,
        gettext("Días operados mínimos (de 30)"),
        gettext("Con menos días operados, el objeto se trata como sin historial confiable."),
        :integer,
        0,
        30
      ),
      e(
        [:anti_scam, :no_history_max_roi],
        :anti_scam,
        gettext("ROI máximo sin historial"),
        gettext("Sin historial, un ROI mayor que este se considera sospechoso."),
        :percent,
        0.01,
        100
      )
    ]
  end

  defp liquidity do
    [
      e(
        [:liquidity, :full_at_days],
        :liquidity,
        gettext("Días de volumen para liquidez plena"),
        gettext("Liquidez 1 si la cantidad no supera el volumen de esta cantidad de días."),
        :integer,
        1,
        30
      ),
      e(
        [:liquidity, :min_days_traded],
        :liquidity,
        gettext("Días operados para no ser ilíquido"),
        gettext("Con menos días operados en 30, el contrato lleva el sello ilíquido."),
        :integer,
        0,
        30
      ),
      e(
        [:default_liquidity],
        :liquidity,
        gettext("Liquidez sin historial"),
        gettext("Valor neutro que se usa mientras no llega el historial del objeto."),
        :percent,
        0,
        1
      ),
      e(
        [:staleness_minutes, 0],
        :liquidity,
        gettext("Datos degradados desde (minutos)"),
        gettext("Desde esta edad los datos del mercado bajan la Certeza."),
        :integer,
        1,
        240
      ),
      e(
        [:staleness_minutes, 1],
        :liquidity,
        gettext("Datos viejos desde (minutos)"),
        gettext("Desde esta edad la baja de la Certeza es mayor."),
        :integer,
        1,
        240
      ),
      e(
        [:staleness_minutes, 2],
        :liquidity,
        gettext("Datos descartados desde (minutos)"),
        gettext("Con datos más viejos que esto la oportunidad no se propone."),
        :integer,
        1,
        480
      ),
      e(
        [:order_tau_min],
        :liquidity,
        gettext("Vida media de las órdenes (minutos)"),
        gettext(
          "Cuánto suele durar una orden en el mercado: cuanto más lejos está el trade, más baja la Certeza."
        ),
        :integer,
        5,
        2_880
      )
    ]
  end

  defp tvs do
    [
      e(
        [:tvs_weights, :isk_per_hour],
        :tvs,
        gettext("Peso del ISK/h"),
        gettext("Cuánto cuenta el beneficio por hora de viaje."),
        :percent,
        0,
        1
      ),
      e(
        [:tvs_weights, :profit],
        :tvs,
        gettext("Peso del beneficio"),
        gettext("Cuánto cuenta el beneficio total del contrato."),
        :percent,
        0,
        1
      ),
      e(
        [:tvs_weights, :roi],
        :tvs,
        gettext("Peso del ROI"),
        gettext("Cuánto cuenta el retorno sobre la inversión."),
        :percent,
        0,
        1
      ),
      e(
        [:tvs_weights, :liquidity],
        :tvs,
        gettext("Peso de la liquidez"),
        gettext("Cuánto cuenta que el objeto se venda sin esperar."),
        :percent,
        0,
        1
      ),
      e(
        [:tvs_refs, :isk_per_hour],
        :tvs,
        gettext("ISK/h de referencia"),
        gettext("Con este ISK/h el factor llega a su máximo."),
        :isk,
        1,
        100_000_000_000
      ),
      e(
        [:tvs_refs, :profit],
        :tvs,
        gettext("Beneficio de referencia"),
        gettext("Con este beneficio el factor llega a su máximo."),
        :isk,
        1,
        1_000_000_000_000
      ),
      e(
        [:tvs_refs, :roi],
        :tvs,
        gettext("ROI de referencia"),
        gettext("Con este ROI el factor llega a su máximo."),
        :percent,
        0.001,
        100
      )
    ]
  end

  defp travel do
    for(
      class <- @ship_classes,
      do:
        e(
          [:jump_seconds, class],
          :travel,
          ship_class_label(class),
          gettext("Segundos por salto, con alineación y warp incluidos."),
          :integer,
          1,
          600
        )
    ) ++
      [
        e(
          [:stop_overhead_s],
          :travel,
          gettext("Tiempo por parada (s)"),
          gettext("Atracar, comprar o vender y volver a salir, en cada estación."),
          :integer,
          0,
          3_600
        )
      ]
  end

  defp vulnerability do
    for class <- @ship_classes, threat <- @threats do
      e(
        [:vulnerability, class, threat],
        :vulnerability,
        "#{ship_class_label(class)} · #{threat_label(threat)}",
        gettext("Probabilidad de perder esta clase de nave ante esta amenaza."),
        :percent,
        0,
        1
      )
    end
  end

  defp board do
    [
      e(
        [:board_hover_freeze],
        :board,
        gettext("Congelar con el puntero sobre la grilla"),
        gettext(
          "Mientras el mouse está sobre la tabla los cambios quedan pendientes y se aplican al salir."
        ),
        :boolean,
        nil,
        nil
      )
    ]
  end

  @doc "Nombre de una clase de nave."
  @spec ship_class_label(atom()) :: String.t()
  def ship_class_label(:freighter), do: gettext("Freighter")
  def ship_class_label(:industrial), do: gettext("Industrial")
  def ship_class_label(:deep_space_transport), do: gettext("Deep Space Transport")
  def ship_class_label(:blockade_runner), do: gettext("Blockade Runner")
  def ship_class_label(:shuttle), do: gettext("Shuttle")
  def ship_class_label(:other), do: gettext("Otras")

  @doc "Nombre de una amenaza."
  @spec threat_label(atom()) :: String.t()
  def threat_label(:gate_camp), do: gettext("Gatecamp")
  def threat_label(:bubble_camp), do: gettext("Bubble camp")
  def threat_label(:smartbomb_camp), do: gettext("Smartbombs")
  def threat_label(:hauler_gank), do: gettext("Gank de transportes")
  def threat_label(:roaming), do: gettext("Actividad hostil")

  defp e(path, group, label, help, kind, min, max) do
    %{
      key: Enum.map_join(path, ".", &to_string/1),
      path: path,
      group: group,
      label: label,
      help: help,
      kind: kind,
      min: min,
      max: max
    }
  end

  ## Valores

  @doc "Valor por defecto del parámetro (el de la configuración)."
  @spec default(entry()) :: term()
  def default(%{path: [top | rest]}), do: dig(GameRules.default(top), rest)

  @doc "Valor vigente (con override si lo hay)."
  @spec current(entry()) :: term()
  def current(%{path: [top | rest]}), do: dig(GameRules.get(top), rest)

  @doc """
  Valida un valor ya convertido: tipo y rango. Devuelve el valor normalizado.
  """
  @spec validate(entry(), term()) :: {:ok, term()} | :error
  def validate(%{kind: :boolean}, value) when is_boolean(value), do: {:ok, value}

  def validate(%{kind: kind} = entry, value)
      when kind in [:integer, :isk] and is_integer(value),
      do: in_range(entry, value)

  def validate(%{kind: kind} = entry, value) when kind in [:float, :percent] and is_number(value),
    do: in_range(entry, value / 1)

  def validate(_entry, _value), do: :error

  defp in_range(%{min: min, max: max}, value) when value >= min and value <= max, do: {:ok, value}
  defp in_range(_entry, _value), do: :error

  @doc """
  Overrides por clave de primer nivel: cada valor guardado se escribe sobre el valor por
  defecto de su clave (`%{anti_scam: %{...mapa completo...}}`). Los guardados inválidos o
  de parámetros que ya no existen se ignoran.
  """
  @spec merge(%{String.t() => term()}) :: %{atom() => term()}
  def merge(stored) do
    for {key, value} <- stored,
        %{} = entry <- [fetch(key)],
        {:ok, value} <- [validate(entry, value)],
        reduce: %{} do
      acc ->
        [top | rest] = entry.path
        base = Map.get_lazy(acc, top, fn -> GameRules.default(top) end)
        Map.put(acc, top, put(base, rest, value))
    end
  end

  defp dig(value, []), do: value
  defp dig(tuple, [i | rest]) when is_tuple(tuple), do: dig(elem(tuple, i), rest)
  defp dig(map, [k | rest]) when is_map(map), do: dig(Map.fetch!(map, k), rest)

  defp put(_value, [], new), do: new

  defp put(tuple, [i | rest], new) when is_tuple(tuple),
    do: put_elem(tuple, i, put(elem(tuple, i), rest, new))

  defp put(map, [k | rest], new) when is_map(map),
    do: Map.put(map, k, put(Map.fetch!(map, k), rest, new))
end
