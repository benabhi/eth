defmodule Eth.Events.Event do
  @moduledoc "Evento del sistema (RF-8.7)."
  use Ecto.Schema

  @levels ~w(info warning error action)

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          at: DateTime.t(),
          level: String.t(),
          source: String.t(),
          message: String.t(),
          metadata: map()
        }

  schema "system_events" do
    field :at, :utc_datetime_usec
    field :level, :string
    field :source, :string
    field :message, :string
    field :metadata, :map, default: %{}
  end

  @doc "Niveles válidos (`action` = acción manual del usuario)."
  @spec levels() :: [String.t()]
  def levels, do: @levels
end
