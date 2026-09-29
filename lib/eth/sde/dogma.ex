defmodule Eth.Sde.Dogma do
  @moduledoc """
  Subconjunto del motor de atributos (dogma) de EVE para calcular la **bodega general**
  de una nave con las habilidades del piloto y los módulos montados (RF-5.8).

  **Extracción** (`build/4`): de `typeDogma`, `dogmaEffects` y `dogmaAttributes` del SDE
  se guardan solo los modificadores `ItemModifier` sobre la nave (`shipID`) o el propio
  ítem (`itemID`) que afectan a la capacidad, directa o indirectamente (clausura desde el
  atributo de capacidad: p. ej. `shipBonusGI` modifica la capacidad y la habilidad
  Gallente Industrial premultiplica `shipBonusGI` por su nivel).

  **Evaluación** (`attribute_value/4`): valor base del atributo más los modificadores
  en el orden de dogma (PreAssign, PreMul, PreDiv, ModAdd, ModSub, PostMul, PostDiv,
  PostPercent, PostAssign) y penalización por apilamiento para atributos no apilables
  modificados por módulos. El nivel de una habilidad es su nivel activo en ESI.

  No contempla efectos sobre otros ítems (`LocationGroupModifier`, etc.) ni el estado
  activo de los módulos: los que modifican la bodega (expansores, rigs, subsistemas)
  son pasivos.

  Implementa: RF-5.8.
  """

  alias Eth.GameRules

  @type modifier ::
          {:ship | :self, modified :: pos_integer(), modifying :: pos_integer(),
           operation :: integer()}
  @type t :: %{
          attributes: %{pos_integer() => %{default: float(), stackable: boolean()}},
          types: %{pos_integer() => %{attrs: map(), mods: [modifier()]}}
        }
  @type fit :: %{
          ship_type_id: pos_integer(),
          base_capacity: float(),
          modules: [pos_integer()],
          skills: %{pos_integer() => 0..5}
        }

  # Orden de aplicación de las operaciones de dogma.
  @operation_order [-1, 0, 1, 2, 3, 4, 5, 6, 7]
  # Operaciones multiplicativas sujetas a penalización por apilamiento.
  @penalized [0, 1, 4, 5, 6]
  @max_depth 8

  ## Extracción

  @doc """
  Arma el subconjunto a partir de las filas del SDE (enumerables de mapas JSON) para el
  atributo `root` (capacidad).
  """
  @spec build(Enumerable.t(), Enumerable.t(), Enumerable.t(), pos_integer()) :: t()
  def build(type_rows, effect_rows, attribute_rows, root) do
    effects =
      effect_rows
      |> Enum.map(&{&1["_key"], modifiers(&1)})
      |> Enum.reject(fn {_id, mods} -> mods == [] end)
      |> Map.new()

    relevant = closure(MapSet.new([root]), effects |> Map.values() |> List.flatten())

    effects =
      effects
      |> Map.new(fn {id, mods} ->
        {id, Enum.filter(mods, &MapSet.member?(relevant, elem(&1, 1)))}
      end)
      |> Map.reject(fn {_id, mods} -> mods == [] end)

    %{
      attributes:
        for(
          a <- attribute_rows,
          MapSet.member?(relevant, a["_key"]),
          into: %{},
          do:
            {a["_key"],
             %{default: (a["defaultValue"] || 0) / 1, stackable: a["stackable"] != false}}
        ),
      types: types(type_rows, effects, relevant)
    }
  end

  defp modifiers(effect) do
    for %{"func" => "ItemModifier", "domain" => domain} = m <- effect["modifierInfo"] || [],
        domain in ["shipID", "itemID"],
        do:
          {if(domain == "shipID", do: :ship, else: :self), m["modifiedAttributeID"],
           m["modifyingAttributeID"], m["operation"]}
  end

  # Atributos que influyen en `root`: los modificados relevantes arrastran a sus
  # modificadores, hasta un punto fijo.
  defp closure(relevant, mods) do
    next =
      Enum.reduce(mods, relevant, fn {_domain, modified, modifying, _op}, acc ->
        if MapSet.member?(acc, modified), do: MapSet.put(acc, modifying), else: acc
      end)

    if MapSet.equal?(next, relevant), do: relevant, else: closure(next, mods)
  end

  defp types(type_rows, effects, relevant) do
    for row <- type_rows,
        mods = Enum.flat_map(row["dogmaEffects"] || [], &Map.get(effects, &1["effectID"], [])),
        attrs =
          for(
            %{"attributeID" => id, "value" => value} <- row["dogmaAttributes"] || [],
            MapSet.member?(relevant, id),
            into: %{},
            do: {id, value / 1}
          ),
        mods != [] or attrs != %{},
        into: %{},
        do: {row["_key"], %{attrs: attrs, mods: mods}}
  end

  ## Evaluación

  @doc """
  Bodega general de una nave con sus módulos y las habilidades del piloto (m³).
  `nil` si no hay datos de dogma.
  """
  @spec cargo_capacity(t() | nil, fit()) :: float() | nil
  def cargo_capacity(nil, _fit), do: nil

  def cargo_capacity(dogma, fit) do
    attribute_value(dogma, fit, :ship, GameRules.get(:dogma_capacity_attribute_id))
  end

  @doc "Valor de un atributo de un ítem del ajuste (`:ship`, `{:module, i}`, `{:skill, id}`)."
  @spec attribute_value(t(), fit(), term(), pos_integer(), non_neg_integer()) :: float()
  def attribute_value(dogma, fit, item, attribute, depth \\ 0)

  def attribute_value(dogma, fit, item, attribute, depth) do
    fit = Map.put_new_lazy(fit, :sources, fn -> sources(dogma, fit) end)

    cond do
      # El nivel de una habilidad es el activo según ESI (contempla cuentas Alpha).
      match?({:skill, _id}, item) and
          attribute == GameRules.get(:dogma_skill_level_attribute_id) ->
        {:skill, id} = item
        Map.get(fit.skills, id, 0) / 1

      depth >= @max_depth ->
        base_value(dogma, fit, item, attribute)

      true ->
        fit.sources
        |> Enum.flat_map(&modifiers_for(dogma, fit, &1, item, attribute, depth))
        |> apply_modifiers(base_value(dogma, fit, item, attribute), stackable?(dogma, attribute))
    end
  end

  defp base_value(dogma, fit, :ship, attribute) do
    if attribute == GameRules.get(:dogma_capacity_attribute_id),
      do: fit.base_capacity / 1,
      else: type_attribute(dogma, fit.ship_type_id, attribute)
  end

  defp base_value(dogma, fit, {:module, index}, attribute),
    do: type_attribute(dogma, Enum.at(fit.modules, index), attribute)

  defp base_value(dogma, _fit, {:skill, id}, attribute),
    do: type_attribute(dogma, id, attribute)

  defp type_attribute(dogma, type_id, attribute) do
    case dogma.types[type_id] do
      %{attrs: %{^attribute => value}} -> value
      _ -> get_in(dogma, [:attributes, attribute, :default]) || 0.0
    end
  end

  # Ítems que aportan modificadores: la nave, sus módulos y **todas** las habilidades del
  # subconjunto (las que tienen nivel): una que el piloto no tiene cuenta como nivel 0 y
  # anula el bono que premultiplica (sin Gallente Hauler, la Iteron no suma su 5 %).
  defp sources(dogma, fit) do
    level_attribute = GameRules.get(:dogma_skill_level_attribute_id)

    modules =
      fit.modules
      |> Enum.with_index()
      |> Enum.map(fn {type_id, i} -> {{:module, i}, type_id, :module} end)

    skills =
      for {id, %{attrs: attrs}} <- dogma.types,
          Map.has_key?(attrs, level_attribute),
          do: {{:skill, id}, id, :skill}

    [{:ship, fit.ship_type_id, :ship} | modules] ++ skills
  end

  defp modifiers_for(dogma, fit, {source, type_id, kind}, target, attribute, depth) do
    for {domain, ^attribute, modifying, op} <- get_in(dogma, [:types, type_id, :mods]) || [],
        applies_to(domain, source) == target do
      {op, attribute_value(dogma, fit, source, modifying, depth + 1), kind}
    end
  end

  defp applies_to(:ship, _source), do: :ship
  defp applies_to(:self, source), do: source

  defp stackable?(dogma, attribute),
    do: get_in(dogma, [:attributes, attribute, :stackable]) != false

  defp apply_modifiers(mods, base, stackable?) do
    by_op = Enum.group_by(mods, &elem(&1, 0))

    Enum.reduce(@operation_order, base, fn op, value ->
      case Map.get(by_op, op, []) do
        [] -> value
        op_mods -> apply_operation(op, value, factors(op, op_mods, stackable?))
      end
    end)
  end

  # Valores de una operación; los multiplicativos de módulos se penalizan si el atributo
  # no es apilable (fórmula de dogma: e^-((n/2.67)^2), por signo y de mayor a menor).
  defp factors(op, mods, stackable?) do
    if op in @penalized and not stackable? do
      {penalized, free} = Enum.split_with(mods, fn {_op, _value, kind} -> kind == :module end)
      Enum.map(free, &elem(&1, 1)) ++ penalize(op, Enum.map(penalized, &elem(&1, 1)))
    else
      Enum.map(mods, &elem(&1, 1))
    end
  end

  defp penalize(op, values) do
    {up, down} = Enum.split_with(values, &(multiplier(op, &1) >= 1.0))

    [Enum.sort_by(up, &multiplier(op, &1), :desc), Enum.sort_by(down, &multiplier(op, &1))]
    |> Enum.flat_map(fn group ->
      group
      |> Enum.with_index()
      |> Enum.map(fn {value, n} ->
        weight = :math.exp(-:math.pow(n / 2.67, 2))
        from_multiplier(op, 1 + (multiplier(op, value) - 1) * weight)
      end)
    end)
  end

  defp multiplier(6, value), do: 1 + value / 100
  defp multiplier(1, value), do: 1 / value
  defp multiplier(5, value), do: 1 / value
  defp multiplier(_op, value), do: value

  defp from_multiplier(6, m), do: (m - 1) * 100
  defp from_multiplier(op, m) when op in [1, 5], do: 1 / m
  defp from_multiplier(_op, m), do: m

  defp apply_operation(-1, _value, values), do: List.last(values)
  defp apply_operation(7, _value, values), do: List.last(values)

  defp apply_operation(op, value, values) when op in [0, 4],
    do: Enum.reduce(values, value, &(&2 * &1))

  defp apply_operation(op, value, values) when op in [1, 5],
    do: Enum.reduce(values, value, &safe_div(&2, &1))

  defp apply_operation(2, value, values), do: value + Enum.sum(values)
  defp apply_operation(3, value, values), do: value - Enum.sum(values)
  defp apply_operation(6, value, values), do: Enum.reduce(values, value, &(&2 * (1 + &1 / 100)))

  defp safe_div(value, divisor) when abs(divisor) < 1.0e-12, do: value
  defp safe_div(value, divisor), do: value / divisor
end
