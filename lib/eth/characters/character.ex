defmodule Eth.Characters.Character do
  @moduledoc "Personaje vinculado por EVE SSO (RF-5.1, RF-5.3)."
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  @token_statuses ~w(ok relogin)

  @type t :: %__MODULE__{}

  schema "characters" do
    field :name, :string
    field :owner_hash, :string
    field :scopes, {:array, :string}, default: []
    field :refresh_token, Eth.Encrypted.Binary, redact: true
    field :token_status, :string, default: "ok"
    field :last_login_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset de login (datos verificados del JWT y tokens del SSO)."
  @spec login_changeset(t(), map()) :: Ecto.Changeset.t()
  def login_changeset(character, attrs) do
    character
    |> cast(attrs, [
      :id,
      :name,
      :owner_hash,
      :scopes,
      :refresh_token,
      :token_status,
      :last_login_at
    ])
    |> validate_required([:id, :name, :owner_hash, :refresh_token, :last_login_at])
    |> validate_inclusion(:token_status, @token_statuses)
  end
end
