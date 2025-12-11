defmodule DecisionEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start Phoenix PubSub so LiveView and channels can broadcast
      {Phoenix.PubSub, name: DecisionEngine.PubSub},
      # Start the endpoint so the web interface is available
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
