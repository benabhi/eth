defmodule Eth.ConfigTransfer do
  @moduledoc """
  Exportar e importar la configuración del operador (RF-9.7) como JSON, para pasarla a
  otra instalación o guardarla antes de reinstalar.

  Incluye solo ajustes, **nunca secretos**: overrides de reglas del juego (RF-9.4),
  radar (RF-9.5), regla de alertas (RF-10.3), perfiles de nave (RF-9.3) y estructuras
  seguidas con su broker fee (RF-9.6). Los personajes y sus tokens no se exportan: en otra
  instalación hay que volver a iniciar sesión con EVE.

  La importación reemplaza cada sección que trae el archivo, valida todo con las mismas
  reglas que la UI (a través de las APIs públicas de cada contexto) e informa lo que
  aplicó y lo que descartó. Las claves desconocidas se ignoran: nunca se convierten en
  átomos.

  Implementa: RF-9.7.
  """

  alias Eth.{Accounts, Characters, Clock, Events, GameRules, Market}
  alias Eth.Market.Structures

  @format 1
  @app "eth"

  @type summary :: %{applied: [String.t()], skipped: [String.t()]}

  @doc "Configuración actual como mapa listo para `Jason.encode!/2`."
  @spec export() :: map()
  def export do
    radar = Accounts.radar_settings()
    rule = Accounts.notification_rule()

    %{
      "app" => @app,
      "format" => @format,
      "exported_at" => DateTime.to_iso8601(Clock.utc_now()),
      "game_rules" =>
        Map.new(Accounts.game_rule_overrides(), fn {key, value} ->
          {Atom.to_string(key), value}
        end),
      "radar" => %{
        "evasive_alpha" => radar.evasive_alpha,
        "avoid_system_ids" => radar.avoid_system_ids
      },
      "notifications" => %{
        "enabled" => rule.enabled,
        "min_tvs" => rule.min_tvs,
        "min_profit" => rule.min_profit
      },
      "ship_profiles" =>
        for p <- Characters.list_ship_profiles() do
          %{
            "ship_item_id" => p.ship_item_id,
            "ship_type_id" => p.ship_type_id,
            "name" => p.name,
            "cargo_m3" => p.cargo_m3,
            "evasion_class" => p.evasion_class,
            "max_cargo_value" => p.max_cargo_value
          }
        end,
      "structures" =>
        for s <- Structures.list(), s.followed or not is_nil(s.broker_fee_override) do
          %{
            "id" => s.id,
            "followed" => s.followed,
            "broker_fee_override" => s.broker_fee_override
          }
        end
    }
  end

  @doc "Nombre sugerido del archivo exportado."
  @spec filename() :: String.t()
  def filename, do: "eth-config-#{Date.to_iso8601(DateTime.to_date(Clock.utc_now()))}.json"

  @doc """
  Importa una configuración ya decodificada. Devuelve qué secciones se aplicaron y qué
  se descartó (con el motivo), o `{:error, motivo}` si el archivo no es de esta app.
  """
  @spec import(term()) :: {:ok, summary()} | {:error, String.t()}
  def import(%{"app" => @app, "format" => @format} = config) do
    summary =
      %{applied: [], skipped: []}
      |> section(config, "game_rules", &import_rules/2)
      |> section(config, "radar", &import_radar/2)
      |> section(config, "notifications", &import_notifications/2)
      |> section(config, "ship_profiles", &import_ships/2)
      |> section(config, "structures", &import_structures/2)
      |> then(&%{applied: Enum.reverse(&1.applied), skipped: Enum.reverse(&1.skipped)})

    Events.emit(
      :action,
      "Usuario",
      "Configuración importada: #{Enum.join(summary.applied, ", ")}" <>
        if(summary.skipped == [], do: "", else: " · #{length(summary.skipped)} descartados")
    )

    {:ok, summary}
  end

  def import(%{"app" => @app}), do: {:error, "El archivo es de un formato más nuevo o distinto."}
  def import(_other), do: {:error, "El archivo no es una configuración de EVE Trade Hunter."}

  defp section(summary, config, key, fun) do
    case Map.fetch(config, key) do
      {:ok, value} -> fun.(value, summary)
      :error -> summary
    end
  end

  defp applied(summary, text), do: %{summary | applied: [text | summary.applied]}
  defp skipped(summary, text), do: %{summary | skipped: [text | summary.skipped]}

  ## Secciones

  # Reemplaza los overrides: las reglas que no trae el archivo vuelven al valor por
  # defecto. Solo claves conocidas (sin crear átomos).
  defp import_rules(rules, summary) when is_map(rules) do
    known = Map.new(GameRules.overridable(), fn {key, _label} -> {Atom.to_string(key), key} end)

    summary =
      Enum.reduce(rules, summary, fn {name, value}, acc ->
        with {:ok, key} <- Map.fetch(known, name),
             :ok <- Accounts.put_game_rule(key, value) do
          acc
        else
          _ -> skipped(acc, "regla #{name}")
        end
      end)

    for {name, key} <- known, not Map.has_key?(rules, name), do: Accounts.reset_game_rule(key)
    applied(summary, "reglas")
  end

  defp import_rules(_other, summary), do: skipped(summary, "reglas (formato inválido)")

  defp import_radar(%{"evasive_alpha" => alpha, "avoid_system_ids" => ids}, summary)
       when is_list(ids) do
    case Accounts.put_radar_settings(alpha, ids) do
      :ok -> applied(summary, "radar")
      {:error, _} -> skipped(summary, "radar (valores fuera de rango)")
    end
  end

  defp import_radar(_other, summary), do: skipped(summary, "radar (formato inválido)")

  defp import_notifications(
         %{"enabled" => enabled, "min_tvs" => tvs, "min_profit" => profit},
         summary
       ) do
    case Accounts.put_notification_rule(%{enabled: enabled, min_tvs: tvs, min_profit: profit}) do
      :ok -> applied(summary, "alertas")
      {:error, _} -> skipped(summary, "alertas (valores fuera de rango)")
    end
  end

  defp import_notifications(_other, summary), do: skipped(summary, "alertas (formato inválido)")

  defp import_ships(profiles, summary) when is_list(profiles) do
    {ok, summary} =
      Enum.reduce(profiles, {0, summary}, fn profile, {ok, acc} ->
        case import_ship(profile) do
          {:ok, _} -> {ok + 1, acc}
          _ -> {ok, skipped(acc, "perfil de nave #{inspect(profile["ship_type_id"])}")}
        end
      end)

    applied(summary, "#{ok} perfiles de nave")
  end

  defp import_ships(_other, summary), do: skipped(summary, "naves (formato inválido)")

  defp import_ship(%{"ship_type_id" => type_id} = p) when is_integer(type_id) do
    item_id = p["ship_item_id"]
    attrs = Map.take(p, ~w(name cargo_m3 evasion_class max_cargo_value))

    if is_nil(item_id) or is_integer(item_id),
      do: Characters.save_ship_profile(item_id, type_id, attrs, apply_to_hull: is_nil(item_id)),
      else: :error
  end

  defp import_ship(_profile), do: :error

  defp import_structures(structures, summary) when is_list(structures) do
    {ok, summary} =
      Enum.reduce(structures, {0, summary}, fn s, {ok, acc} ->
        case import_structure(s) do
          :ok -> {ok + 1, acc}
          _ -> {ok, skipped(acc, "estructura #{inspect(s["id"])}")}
        end
      end)

    applied(summary, "#{ok} estructuras")
  end

  defp import_structures(_other, summary), do: skipped(summary, "estructuras (formato inválido)")

  defp import_structure(%{"id" => id} = s) when is_integer(id) and id > 0 do
    {:ok, _} = Structures.follow(id)

    Market.update_structure(id, %{
      followed: s["followed"] == true,
      broker_fee_override: s["broker_fee_override"]
    })
  end

  defp import_structure(_structure), do: :error
end
