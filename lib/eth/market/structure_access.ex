defmodule Eth.Market.StructureAccess do
  @moduledoc """
  Acceso de un personaje al mercado de una estructura (RF-1.6, ERS §7.2): `ok`,
  `forbidden` (un 403; no se reintenta antes de 24 h) o `unknown`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "structure_access" do
    field :structure_id, :integer, primary_key: true
    field :character_id, :integer, primary_key: true
    field :status, :string
    field :checked_at, :utc_datetime
    field :last_error, :string
  end
end
