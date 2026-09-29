defmodule Eth.Vault do
  @moduledoc """
  Bóveda de cifrado para datos sensibles en reposo (RNF-4.2): los refresh tokens de
  EVE SSO se guardan cifrados con AES-256-GCM usando `ETH_VAULT_KEY` (32 bytes en
  Base64).

  Sin clave configurada, la bóveda arranca con una clave efímera y el login queda
  deshabilitado (`Eth.Sso.configured?/0`): nunca se guarda un token que después no se
  pueda descifrar.

  Implementa: RNF-4.2.
  """
  use Cloak.Vault, otp_app: :eth

  require Logger

  @impl GenServer
  def init(config) do
    key =
      case decode_key(Application.get_env(:eth, __MODULE__, [])[:key]) do
        {:ok, key} ->
          key

        :error ->
          Logger.warning(
            "ETH_VAULT_KEY no configurada o inválida: el login con EVE SSO queda deshabilitado"
          )

          :crypto.strong_rand_bytes(32)
      end

    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key, iv_length: 12}
      )

    {:ok, config}
  end

  @doc "¿Hay una clave válida configurada?"
  @spec configured?() :: boolean()
  def configured? do
    match?({:ok, _}, decode_key(Application.get_env(:eth, __MODULE__, [])[:key]))
  end

  defp decode_key(nil), do: :error

  defp decode_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _ -> :error
    end
  end
end
