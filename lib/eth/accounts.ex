defmodule Eth.Accounts do
  @moduledoc """
  Operador de la instancia y sus ajustes (ERS §2.3, §7.2). En el modo de operador único
  hay una sola fila en `operators`, que se crea al primer uso.

  Por ahora los ajustes guardan los overrides de las reglas del juego (RF-9.4), en
  `settings["game_rules"]` como `%{"sales_tax_base" => 0.075, ...}`.

  Implementa: RF-9.4, RNF-15.2.
  """

  alias Eth.Accounts.Operator
  alias Eth.Engine.Coordinator
  alias Eth.{Events, GameRules, Repo}
  alias Eth.GameRules.Overrides

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
