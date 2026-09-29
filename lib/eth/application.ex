defmodule Eth.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      EthWeb.Telemetry,
      Eth.Repo,
      {DNSCluster, query: Application.get_env(:eth, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Eth.PubSub},
      # Pool HTTP: el tamaño del pool de ESI acota la concurrencia global de requests.
      {Finch, name: Eth.Finch, pools: %{"https://esi.evetech.net" => [size: 16, count: 1]}},
      Eth.Esi.Budget,
      EthWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Eth.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EthWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
