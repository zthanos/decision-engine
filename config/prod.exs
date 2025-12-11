# config/prod.exs
import Config

config :decision_engine, DecisionEngineWeb.Endpoint,
  url: [host: "example.com", port: 443, scheme: "https"],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

# lib/decision_engine/application.ex
defmodule DecisionEngine.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DecisionEngineWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:decision_engine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DecisionEngine.PubSub},
      DecisionEngineWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: DecisionEngine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    DecisionEngineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
