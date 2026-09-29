defmodule Eth.Characters.ShipProfile do
  @moduledoc """
  Perfil de carga de una nave (RF-5.8): capacidad de la bodega **general** (m³), clase de
  evasión y valor máximo de carga opcional. Clave por `ship_item_id` (la nave concreta,
  dos naves del mismo casco pueden tener distinto fitting) con *fallback* por casco.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @evasion_classes ~w(shuttle blockade_runner deep_space_transport industrial freighter other)

  @type t :: %__MODULE__{}

  schema "ship_profiles" do
    field :ship_item_id, :integer
    field :ship_type_id, :integer
    field :name, :string
    field :cargo_m3, :float
    field :evasion_class, :string
    field :max_cargo_value, :float

    timestamps(type: :utc_datetime)
  end

  @doc "Clases de evasión válidas (coinciden con `:jump_seconds` de GameRules)."
  @spec evasion_classes() :: [String.t()]
  def evasion_classes, do: @evasion_classes

  @doc "Changeset desde el formulario (los IDs de nave se fijan aparte, no desde params)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :cargo_m3, :evasion_class, :max_cargo_value])
    |> validate_required([:cargo_m3, :evasion_class])
    |> validate_number(:cargo_m3, greater_than: 0, less_than: 10_000_000)
    |> validate_number(:max_cargo_value, greater_than: 0)
    |> validate_inclusion(:evasion_class, @evasion_classes)
    |> unique_constraint(:ship_item_id)
    |> unique_constraint(:ship_type_id, name: :ship_profiles_hull_index)
  end
end
