defmodule Eth.GameRules do
  @moduledoc """
  Acceso a las reglas del juego y parámetros calibrables (ERS Anexo B).

  Los valores viven en la configuración (`config :eth, Eth.GameRules`) y nunca como
  literales en el código: CCP los cambia (impuestos, regiones especiales, límites).

  Algunas reglas (impuestos y coeficientes del broker) admiten un **override** desde
  Ajustes sin recompilar (RF-9.4, RNF-15.2): se guardan en los ajustes del operador y
  `Eth.GameRules.Overrides` los publica en ETS, donde `get/1` los consulta primero.

  Implementa: RNF-15.1, RNF-15.2, RF-9.4.
  """

  @overrides_table :eth_game_rule_overrides
  @config_cache {__MODULE__, :config}

  # Reglas que admiten override: clave => descripción (valores en proporción, 0,075 = 7,5 %).
  @overridable [
    sales_tax_base: "Sales tax base",
    accounting_reduction_per_level: "Reducción del sales tax por nivel de Accounting",
    broker_fee_base: "Broker fee base",
    broker_relations_reduction_per_level:
      "Reducción del broker fee por nivel de Broker Relations",
    broker_faction_standing_coef: "Reducción del broker fee por punto de standing de facción",
    broker_corp_standing_coef: "Reducción del broker fee por punto de standing de corporación"
  ]

  @doc "Devuelve un parámetro; falla si no está configurado (evita defaults silenciosos)."
  @spec get(atom()) :: term()
  def get(key) do
    case override(key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(config(), key) do
          {:ok, value} ->
            value

          :error ->
            raise ArgumentError, "parámetro de Eth.GameRules no configurado: #{inspect(key)}"
        end
    end
  end

  @doc "Devuelve un parámetro opcional con valor por defecto."
  @spec get(atom(), term()) :: term()
  def get(key, default) do
    case override(key) do
      {:ok, value} -> value
      :error -> Map.get(config(), key, default)
    end
  end

  @doc "Reglas que admiten override: `[{clave, descripción}]`."
  @spec overridable() :: [{atom(), String.t()}]
  def overridable, do: @overridable

  @doc "Valor por defecto (el de la configuración, sin override)."
  @spec default(atom()) :: term()
  def default(key), do: Map.fetch!(config(), key)

  @doc "Tabla ETS de overrides (su dueño es `Eth.GameRules.Overrides`)."
  @spec overrides_table() :: atom()
  def overrides_table, do: @overrides_table

  defp override(key) do
    case :ets.whereis(@overrides_table) do
      :undefined ->
        :error

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> {:ok, value}
          [] -> :error
        end
    end
  end

  @doc """
  Indica si una región debe escanearse (RF-1.2): excluye J-space, abisal/especiales,
  Pochven y el Mercado Global de PLEX; respeta el subconjunto `ETH_REGIONS` si existe.
  """
  @spec scannable_region?(pos_integer()) :: boolean()
  def scannable_region?(region_id) do
    region_id < get(:excluded_region_id_from) and
      region_id not in get(:excluded_region_ids) and
      in_subset?(region_id)
  end

  defp in_subset?(region_id) do
    case get(:only_region_ids, nil) do
      nil -> true
      ids -> region_id in ids
    end
  end

  @doc """
  Vuelve a leer la configuración (tests que la cambian con `Application.put_env/3`). En
  ejecución normal no hace falta: `config/*.exs` cambia solo con un reinicio.
  """
  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@config_cache)
    :ok
  end

  # La configuración se lee de `Application` una vez y queda como mapa en persistent_term:
  # `Application.get_env/2` copia la lista completa en cada llamada, y el motor consulta
  # reglas miles de veces por consulta (RNF-1.1).
  defp config do
    case :persistent_term.get(@config_cache, nil) do
      nil ->
        config = Map.new(Application.get_env(:eth, __MODULE__, []))
        :persistent_term.put(@config_cache, config)
        config

      config ->
        config
    end
  end
end
