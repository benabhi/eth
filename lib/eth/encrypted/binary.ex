defmodule Eth.Encrypted.Binary do
  @moduledoc "Tipo Ecto cifrado con `Eth.Vault` (refresh tokens, RNF-4.2)."
  use Cloak.Ecto.Binary, vault: Eth.Vault
end
