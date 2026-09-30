defmodule Eth.Accounts do
  @moduledoc """
  Operador de la instancia y sus ajustes (ERS §2.3, §7.2). En el modo de operador único
  hay una sola fila en `operators`, que se crea al primer uso.

  Los ajustes guardan los overrides de las reglas del juego (RF-9.4), en
  `settings["game_rules"]` como `%{"sales_tax_base" => 0.075, ...}`, y los del radar
  (RF-9.5) en `settings["radar"]`.

  Implementa: RF-9.4, RF-9.5, RNF-15.2.
  """

  alias Eth.Accounts.Operator
  alias Eth.Engine.Coordinator
  alias Eth.{Events, GameRules, Repo}
  alias Eth.GameRules.{Overrides, Tunable}

  @default_name "Operador"
  # Operador único con ID fijo: la creación concurrente no puede duplicarlo.
  @operator_id 1

  @doc "El operador (lo crea si todavía no existe)."
  @spec operator() :: Operator.t()
  def operator do
    Repo.get(Operator, @operator_id) ||
      (
        Repo.insert!(%Operator{id: @operator_id, name: @default_name, settings: %{}},
          on_conflict: :nothing,
          conflict_target: :id
        )

        Repo.get!(Operator, @operator_id)
      )
  end

  @doc "Overrides vigentes: `%{clave => valor}` (solo claves que admiten override)."
  @spec game_rule_overrides() :: %{atom() => float()}
  def game_rule_overrides do
    stored = Map.get(operator().settings, "game_rules", %{})

    # Claves conocidas únicamente: nunca String.to_atom con datos guardados.
    for {key, _label} <- GameRules.overridable(),
        value = stored[Atom.to_string(key)],
        is_number(value),
        into: %{},
        do: {key, value / 1}
  end

  @doc """
  Fija el override de una regla (valor en proporción, entre 0 y 1). Publica el cambio y
  pide una nueva evaluación del mercado.
  """
  @spec put_game_rule(atom(), number()) :: :ok | {:error, :unknown_rule | :invalid_value}
  def put_game_rule(key, value) do
    cond do
      not Keyword.has_key?(GameRules.overridable(), key) -> {:error, :unknown_rule}
      not (is_number(value) and value >= 0 and value <= 1) -> {:error, :invalid_value}
      true -> update_rules(&Map.put(&1, Atom.to_string(key), value / 1), key, value)
    end
  end

  @doc "Quita el override de una regla (vuelve al valor por defecto)."
  @spec reset_game_rule(atom()) :: :ok | {:error, :unknown_rule}
  def reset_game_rule(key) do
    if Keyword.has_key?(GameRules.overridable(), key),
      do: update_rules(&Map.delete(&1, Atom.to_string(key)), key, nil),
      else: {:error, :unknown_rule}
  end

  ## Parámetros del motor (RF-9.5)

  @doc """
  Parámetros del motor guardados: `%{clave => valor}` con las claves de
  `Eth.GameRules.Tunable` (solo los que siguen existiendo y son válidos).
  """
  @spec engine_overrides() :: %{String.t() => term()}
  def engine_overrides do
    stored = Map.get(operator().settings, "engine", %{})

    for {key, value} <- stored,
        %{} = entry <- [Tunable.fetch(key)],
        {:ok, value} <- [Tunable.validate(entry, value)],
        into: %{},
        do: {key, value}
  end

  @doc """
  Guarda de una vez varios parámetros del motor (`%{clave => valor | nil}`; `nil` vuelve
  al valor por defecto). Valida todo antes de guardar: si uno es inválido no se guarda
  ninguno. Publica el cambio y pide una nueva evaluación.
  """
  @spec put_engine_params(%{String.t() => term()}) :: :ok | {:error, [String.t()]}
  def put_engine_params(changes) do
    checked =
      Enum.map(changes, fn {key, value} -> check_param(Tunable.fetch(key), key, value) end)

    case for({:error, key} <- checked, do: key) do
      [] ->
        operator = operator()

        engine =
          Enum.reduce(checked, Map.get(operator.settings, "engine", %{}), fn
            {:reset, key}, acc -> Map.delete(acc, key)
            {:set, key, value}, acc -> Map.put(acc, key, value)
          end)

        operator
        |> Operator.settings_changeset(Map.put(operator.settings, "engine", engine))
        |> Repo.update!()

        Overrides.reload()
        if GenServer.whereis(Coordinator), do: Coordinator.request()

        Events.emit(
          :action,
          "Usuario",
          "Parámetros del motor: #{map_size(engine)} con valor propio"
        )

        :ok

      invalid ->
        {:error, invalid}
    end
  end

  defp check_param(nil, key, _value), do: {:error, key}
  defp check_param(_entry, key, nil), do: {:reset, key}

  defp check_param(entry, key, value) do
    case Tunable.validate(entry, value) do
      {:ok, value} -> {:set, key, value}
      :error -> {:error, key}
    end
  end

  ## Notificaciones (RF-10.3)

  @rule_defaults %{"enabled" => false, "min_tvs" => 75, "min_profit" => 20_000_000}

  @doc "Regla de oportunidades nuevas: apagada por defecto, TVS ≥ 75 y beneficio ≥ 20M."
  @spec notification_rule() :: %{
          enabled: boolean(),
          min_tvs: non_neg_integer(),
          min_profit: number()
        }
  def notification_rule do
    stored = Map.merge(@rule_defaults, Map.get(operator().settings, "notifications", %{}))

    %{
      enabled: stored["enabled"] == true,
      min_tvs: stored["min_tvs"],
      min_profit: stored["min_profit"]
    }
  end

  @doc "Guarda la regla de oportunidades nuevas (TVS 0–100, beneficio ≥ 0)."
  @spec put_notification_rule(map()) :: :ok | {:error, :invalid_value}
  def put_notification_rule(%{enabled: enabled, min_tvs: tvs, min_profit: profit})
      when is_boolean(enabled) and is_integer(tvs) and tvs in 0..100 and is_number(profit) and
             profit >= 0 do
    operator = operator()
    rule = %{"enabled" => enabled, "min_tvs" => tvs, "min_profit" => profit}

    operator
    |> Operator.settings_changeset(Map.put(operator.settings, "notifications", rule))
    |> Repo.update!()

    Events.emit(
      :action,
      "Usuario",
      "Alertas de contratos nuevos: #{if enabled, do: "TVS ≥ #{tvs}", else: "apagadas"}"
    )

    :ok
  end

  def put_notification_rule(_attrs), do: {:error, :invalid_value}

  ## Radar (RF-9.5)

  @doc """
  Ajustes del radar guardados: `%{evasive_alpha: número | nil, avoid_system_ids: [id]}`.
  Se publican como overrides de `:evasive_alpha` y `:avoid_system_ids`.
  """
  @spec radar_settings() :: %{evasive_alpha: number() | nil, avoid_system_ids: [pos_integer()]}
  def radar_settings do
    stored = Map.get(operator().settings, "radar", %{})
    alpha = stored["evasive_alpha"]
    ids = stored["avoid_system_ids"]

    %{
      evasive_alpha: if(is_number(alpha), do: alpha / 1),
      avoid_system_ids: if(is_list(ids), do: Enum.filter(ids, &is_integer/1), else: [])
    }
  end

  @doc "Overrides del radar para la tabla de reglas (solo los definidos)."
  @spec radar_overrides() :: %{atom() => term()}
  def radar_overrides do
    s = radar_settings()

    %{avoid_system_ids: s.avoid_system_ids}
    |> then(&if(s.evasive_alpha, do: Map.put(&1, :evasive_alpha, s.evasive_alpha), else: &1))
  end

  @doc """
  Guarda α del modo Evasiva (`nil` = valor por defecto; entre 0 y 100) y los sistemas a
  evitar (RF-2.5). Publica el cambio y pide una nueva evaluación.
  """
  @spec put_radar_settings(number() | nil, [pos_integer()]) :: :ok | {:error, :invalid_value}
  def put_radar_settings(alpha, avoid_ids) do
    if (is_nil(alpha) or (is_number(alpha) and alpha >= 0 and alpha <= 100)) and
         Enum.all?(avoid_ids, &is_integer/1) do
      operator = operator()
      radar = %{"evasive_alpha" => alpha, "avoid_system_ids" => Enum.uniq(avoid_ids)}

      operator
      |> Operator.settings_changeset(Map.put(operator.settings, "radar", radar))
      |> Repo.update!()

      Overrides.reload()
      if GenServer.whereis(Coordinator), do: Coordinator.request()

      Events.emit(
        :action,
        "Usuario",
        "Radar: α = #{alpha || "por defecto"} · #{length(avoid_ids)} sistemas a evitar"
      )

      :ok
    else
      {:error, :invalid_value}
    end
  end

  defp update_rules(fun, key, value) do
    operator = operator()
    rules = operator.settings |> Map.get("game_rules", %{}) |> fun.()

    operator
    |> Operator.settings_changeset(Map.put(operator.settings, "game_rules", rules))
    |> Repo.update!()

    Overrides.reload()
    if GenServer.whereis(Coordinator), do: Coordinator.request()

    message =
      if value,
        do: "Regla #{key} = #{value} (override)",
        else: "Regla #{key} vuelve al valor por defecto"

    Events.emit(:action, "Usuario", message)
    :ok
  end
end
