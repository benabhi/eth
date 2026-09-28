defmodule Eth.Repo do
  use Ecto.Repo,
    otp_app: :eth,
    adapter: Ecto.Adapters.Postgres
end
