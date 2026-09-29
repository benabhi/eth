defmodule EthWeb.PilotHook do
  @moduledoc """
  Carga el piloto activo en cada LiveView (RF-5.10, RF-6.1): lee el personaje de la sesión,
  se registra como observador de su sesión (polling en modo activo, RF-5.4) y mantiene
  `@pilot` al día con los mensajes de `character:<id>`.

  También maneja el diálogo de perfil de carga de una nave nueva (RF-5.8), que vive en el
  layout y por eso se atiende aquí y no en cada LiveView.

  Asigna `@pilot` (`nil` en modo invitado), `@characters` y `@ship_form`.

  Implementa: RF-5.7, RF-5.8, RF-5.10, RF-6.1.
  """
  use Gettext, backend: EthWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView

  alias Eth.Characters
  alias Eth.Characters.{Pilot, Session, Sessions}

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, session, socket) do
    characters = Characters.list()
    character = Enum.find(characters, &(&1.id == session["character_id"]))

    socket =
      socket
      |> assign(:characters, characters)
      |> assign(:character, character)
      |> assign(:ship_form, nil)
      |> assign(:pilot, character && Pilot.build(session_context(socket, character), character))
      |> attach_hook(:pilot_info, :handle_info, &handle_info/2)
      |> attach_hook(:pilot_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  # Conectado: se registra como observador (arranca la sesión si hacía falta).
  defp session_context(socket, character) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Eth.PubSub, Session.topic(character.id))
      Sessions.watch(character.id) || start_and_watch(character)
    else
      Sessions.context(character.id)
    end
  end

  defp start_and_watch(%{token_status: "ok"} = character) do
    :ok = Sessions.start(character.id)
    Sessions.watch(character.id)
  end

  defp start_and_watch(_character), do: nil

  ## Mensajes de la sesión del personaje

  defp handle_info({:character, id, event, public}, %{assigns: %{character: %{id: id}}} = socket) do
    previous = socket.assigns.pilot
    pilot = Pilot.build(public, socket.assigns.character)

    socket =
      socket
      |> assign(:pilot, pilot)
      |> maybe_open_ship_dialog(event, previous, pilot)

    # Sigue hacia la LiveView: el Cazador recalcula con el contexto nuevo.
    {:cont, socket}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # Una nave sin perfil abre el diálogo una sola vez, al subirse a ella (RF-5.8).
  defp maybe_open_ship_dialog(socket, :ship, previous, %{ship: %{profile: nil} = ship}) do
    previous_item = previous && previous.ship && previous.ship.ship_item_id

    if previous_item != ship.ship_item_id and is_nil(socket.assigns.ship_form),
      do: assign(socket, :ship_form, ship_form(ship)),
      else: socket
  end

  defp maybe_open_ship_dialog(socket, _event, _previous, _pilot), do: socket

  ## Diálogo de perfil de carga (RF-5.8)

  defp handle_event("pilot_ship_open", _params, socket) do
    case socket.assigns.pilot do
      %{ship: %{} = ship} -> {:halt, assign(socket, :ship_form, ship_form(ship))}
      _ -> {:halt, socket}
    end
  end

  defp handle_event("pilot_ship_close", _params, socket),
    do: {:halt, assign(socket, :ship_form, nil)}

  defp handle_event("pilot_ship_validate", %{"ship_profile" => params}, socket) do
    form =
      params
      |> Characters.change_ship_profile()
      |> Map.put(:action, :validate)
      |> to_form(as: :ship_profile)

    {:halt, assign(socket, :ship_form, form)}
  end

  defp handle_event("pilot_ship_save", %{"ship_profile" => params}, socket) do
    %{pilot: %{ship: ship} = pilot, character: character} = socket.assigns
    apply_to_hull = params["apply_to_hull"] == "true"

    case Characters.save_ship_profile(ship.ship_item_id, ship.ship_type_id, params,
           apply_to_hull: apply_to_hull
         ) do
      {:ok, _profile} ->
        # El perfil cambia bodega y clase: se rearma el piloto y se avisa a la LiveView.
        send(self(), {:character, character.id, :ship_profile, Sessions.context(character.id)})

        {:halt,
         socket
         |> assign(:ship_form, nil)
         |> put_flash(:info, gettext("Perfil de %{ship} guardado", ship: ship.type_name))
         |> assign(:pilot, pilot)}

      {:error, changeset} ->
        {:halt, assign(socket, :ship_form, to_form(changeset, as: :ship_profile))}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # Sugerencias: perfil existente, o capacidad base y clase por grupo del SDE.
  defp ship_form(ship) do
    attrs =
      case ship.profile do
        nil ->
          %{
            "cargo_m3" => ship.base_capacity,
            "evasion_class" => Atom.to_string(ship.evasion_class)
          }

        profile ->
          %{
            "cargo_m3" => profile.cargo_m3,
            "evasion_class" => profile.evasion_class,
            "max_cargo_value" => profile.max_cargo_value
          }
      end

    attrs |> Characters.change_ship_profile() |> to_form(as: :ship_profile)
  end
end
