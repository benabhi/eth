defmodule Eth.Accounts.Operator do
  @moduledoc "Operador de la instancia (modo de operador único, ERS §2.3) y sus ajustes."
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "operators" do
    field :name, :string
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de los ajustes (mapa JSON con claves string)."
  @spec settings_changeset(t(), map()) :: Ecto.Changeset.t()
  def settings_changeset(operator, settings) do
    operator
    |> change(settings: settings)
    |> validate_required([:name])
  end
end
