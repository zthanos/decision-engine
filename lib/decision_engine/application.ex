defmodule DecisionEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start Finch for HTTP client streaming support
      {Finch, name: DecisionEngine.Finch},
      # Start Phoenix PubSub so LiveView and channels can broadcast
      {Phoenix.PubSub, name: DecisionEngine.PubSub},
      # Start the Registry for tracking SSE stream sessions
      {Registry, keys: :unique, name: DecisionEngine.StreamRegistry},
      # Start the RuleConfig cache for domain configurations
      DecisionEngine.RuleConfig,
      # Start the HistoryManager for analysis history persistence
      DecisionEngine.HistoryManager,
      # Start the DescriptionGenerator for LLM-powered domain descriptions
      DecisionEngine.DescriptionGenerator,
      # Start the LLMConfigManager for centralized LLM configuration
      DecisionEngine.LLMConfigManager,
      # Start the StreamingHandler for real-time LLM response streaming
      DecisionEngine.StreamingHandler,
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
