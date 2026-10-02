defmodule Eth.Sde do
  @moduledoc """
  API de datos estáticos del juego (RF-2.2, RF-2.6). Lectura sin copia desde
  `:persistent_term`; los datos los publica `Eth.Sde.Store`.

  Implementa: RF-2.2, RF-2.3, RF-2.6, RF-8.2.
  """

  alias Eth.GameRules
  alias Eth.Sde.Galaxy

  @doc "¿Hay datos cargados?"
  @spec ready?() :: boolean()
  def ready?, do: data() != nil

  @doc "Estado del SDE (para el Centro de control)."
  @spec status() :: map()
  defdelegate status, to: Eth.Sde.Store

  @doc "Tópico PubSub del estado del SDE."
  @spec topic() :: String.t()
  defdelegate topic, to: Eth.Sde.Store

  @doc "Datos procesados completos (`nil` si todavía no se cargaron)."
  @spec data() :: map() | nil
  def data, do: :persistent_term.get({__MODULE__, :data}, nil)

  @doc "Sistema por ID."
  @spec system(pos_integer()) :: map() | nil
  def system(id), do: get(:systems, id)

  @doc "Región por ID."
  @spec region(pos_integer()) :: map() | nil
  def region(id), do: get(:regions, id)

  @doc """
  Mapa de las regiones del espacio conocido para el Centro de control (RF-8.2): posición
  2D de cada una y uniones por stargate (`Eth.Sde.Galaxy`). `nil` sin SDE.
  """
  @spec galaxy() :: Galaxy.layout() | nil
  def galaxy do
    case data() do
      nil -> nil
      d -> Galaxy.regions(d.systems, d.regions)
    end
  end

  @doc "Mapa de los sistemas de una región (RF-8.2). `nil` sin SDE."
  @spec region_map(pos_integer()) :: Galaxy.layout() | nil
  def region_map(region_id) do
    case data() do
      nil -> nil
      d -> Galaxy.region(d.systems, region_id)
    end
  end

  @doc "Estación NPC por ID."
  @spec station(pos_integer()) :: map() | nil
  def station(id), do: get(:stations, id)

  @doc "Tipo de mercado por ID (solo tipos publicados con grupo de mercado)."
  @spec type(pos_integer()) :: map() | nil
  def type(id), do: get(:types, id)

  @doc "Grupo de un tipo de nave o módulo, esté o no en el mercado (radar, RF-3.2)."
  @spec type_group(pos_integer()) :: pos_integer() | nil
  def type_group(id), do: get(:type_groups, id)

  @doc "Corporación NPC por ID (`%{name, faction_id}`): dueña de estaciones (broker fee)."
  @spec corporation(pos_integer()) :: map() | nil
  def corporation(id), do: get(:corporations, id)

  @doc "Grupo del SDE por ID (`%{name, category_id}`)."
  @spec group(pos_integer()) :: map() | nil
  def group(id), do: get(:groups, id)

  @doc "Stargate por ID: `%{system_id, destination_system_id}` (radar, RF-3.2)."
  @spec stargate(pos_integer()) :: map() | nil
  def stargate(id), do: get(:stargates, id)

  @doc "Subconjunto de dogma para calcular la bodega (`Eth.Sde.Dogma`); `nil` sin SDE."
  @spec dogma() :: Eth.Sde.Dogma.t() | nil
  def dogma do
    case data() do
      %{dogma: dogma} -> dogma
      _ -> nil
    end
  end

  @doc "Busca un sistema por nombre exacto (sin distinguir mayúsculas)."
  @spec system_by_name(String.t()) :: {pos_integer(), map()} | nil
  def system_by_name(name) do
    wanted = String.downcase(name)

    case data() do
      nil ->
        nil

      %{systems: systems} ->
        Enum.find(systems, fn {_id, s} -> String.downcase(s.name) == wanted end)
    end
  end

  defp get(collection, id) do
    case data() do
      %{} = data -> data |> Map.get(collection, %{}) |> Map.get(id)
      nil -> nil
    end
  end

  ## Seguridad (RF-2.6, ERS §8.1)

  @doc """
  Seguridad mostrada por el cliente: un decimal, salvo `0 < sec < 0.05`, que se muestra
  como 0.1 (ningún sistema con seguridad positiva aparece como 0.0).
  """
  @spec security_display(float()) :: float()
  def security_display(sec) when sec > 0 and sec < 0.05, do: 0.1
  def security_display(sec), do: Float.round(sec / 1, 1)

  @doc "Banda de seguridad: highsec (≥ 0.45 real, se muestra ≥ 0.5), lowsec o nullsec."
  @spec security_band(float()) :: :highsec | :lowsec | :nullsec
  def security_band(sec) do
    cond do
      sec >= GameRules.get(:highsec_min_security) -> :highsec
      sec > 0 -> :lowsec
      true -> :nullsec
    end
  end

  @colors %{
    1.0 => "#2FEFEF",
    0.9 => "#48F0C0",
    0.8 => "#00EF47",
    0.7 => "#00F000",
    0.6 => "#8FEF2F",
    0.5 => "#EFEF00",
    0.4 => "#D77700",
    0.3 => "#F06000",
    0.2 => "#F04800",
    0.1 => "#D73000"
  }

  @doc "Color aproximado de la escala del cliente para una seguridad real (Anexo B.6)."
  @spec security_color(float()) :: String.t()
  def security_color(sec) do
    display = security_display(sec)
    if display <= 0.0, do: "#F00000", else: Map.fetch!(@colors, display)
  end
end
