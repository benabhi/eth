import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/eth start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :eth, EthWeb.Endpoint, server: true
end

config :eth, EthWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# EVE SSO (RF-5.1) y bóveda de tokens (RNF-4.2). En test se configuran en test.exs.
if config_env() != :test do
  config :eth, Eth.Sso,
    client_id: System.get_env("EVE_CLIENT_ID"),
    client_secret: System.get_env("EVE_CLIENT_SECRET"),
    callback_url: System.get_env("EVE_CALLBACK_URL", "http://localhost:4000/auth/eve/callback"),
    allowed_character_ids:
      System.get_env("ETH_ALLOWED_CHARACTER_IDS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer(String.trim(&1)))

  config :eth, Eth.Vault, key: System.get_env("ETH_VAULT_KEY")
end

# ESI: contacto para el User-Agent (RNF-3.1) y fecha de compatibilidad opcional.
config :eth, Eth.Esi.Client, contact: System.get_env("ESI_CONTACT")

if compatibility_date = System.get_env("ESI_COMPATIBILITY_DATE") do
  config :eth, Eth.Esi.Client, compatibility_date: compatibility_date
end

# Fuente de datos de mercado (RF-1.11): live (ESI) o replay (snapshots grabados, sin red).
config :eth,
       :data_source,
       (case System.get_env("ETH_DATA_SOURCE", "live") do
          "replay" -> :replay
          _ -> :live
        end)

# Feed de killmails del radar (RF-3.1): r2z2 (por defecto) u off. En modo Replay se
# reproducen las kills grabadas sin importar este valor.
config :eth,
       :killfeed,
       (case System.get_env("ETH_KILLFEED", "r2z2") do
          "off" -> :off
          _ -> :r2z2
        end)

# Subconjunto de regiones (ETH_REGIONS=10000002,10000043). Vacío o ausente = todas.
case System.get_env("ETH_REGIONS", "") |> String.split(",", trim: true) do
  [] ->
    :ok

  ids ->
    config :eth, Eth.GameRules,
      only_region_ids: Enum.map(ids, &String.to_integer(String.trim(&1)))
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :eth, EthWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/eth_web/router\.ex$"E,
        ~r"lib/eth_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# Directorio de datos persistentes (SDE procesado, matrices, snapshots). En la imagen de
# producción es un volumen (`/data`) fuera de la release, para que las actualizaciones no
# lo pierdan (RNF-10.7). Sin la variable: `priv/data` (desarrollo).
if data_dir = System.get_env("ETH_DATA_DIR") do
  config :eth, :data_dir, data_dir
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      falta la variable DATABASE_URL (por ejemplo ecto://USUARIO:CLAVE@HOST/BASE).
      docker-compose.release.yml ya la define.
      """

  config :eth, Eth.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # SECRET_KEY_BASE firma las cookies de sesión. Si no se define, se genera una vez y se
  # guarda en el directorio de datos: la instalación queda en un solo paso y la clave
  # sobrevive a las actualizaciones. (La clave de los tokens, ETH_VAULT_KEY, en cambio,
  # la genera y guarda el piloto: ver .env.example.)
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        dir = System.get_env("ETH_DATA_DIR") || raise "falta ETH_DATA_DIR o SECRET_KEY_BASE"
        path = Path.join(dir, "secret_key_base")

        case File.read(path) do
          {:ok, key} when byte_size(key) >= 64 ->
            String.trim(key)

          _ ->
            key = :crypto.strong_rand_bytes(48) |> Base.encode64()
            File.mkdir_p!(dir)
            File.write!(path, key)
            File.chmod!(path, 0o600)
            key
        end
      )

  # Uso personal y local (D-20): HTTP en el puerto publicado solo en 127.0.0.1 del host.
  host = System.get_env("PHX_HOST", "localhost")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :eth, EthWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: ["//localhost", "//127.0.0.1", "//#{host}"],
    secret_key_base: secret_key_base
end
