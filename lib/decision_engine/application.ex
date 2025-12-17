defmodule DecisionEngine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize streaming session storage
    DecisionEngine.StreamingInterface.init_session_storage()

    # Initialize ReqLLM configuration
    DecisionEngine.ReqLLMConfig.init_config()

    children = [
      # Start Finch for HTTP client streaming support
      {Finch, name: DecisionEngine.Finch},
      # Start Phoenix PubSub so LiveView and channels can broadcast
      {Phoenix.PubSub, name: DecisionEngine.PubSub},
      # Start the Registry for tracking SSE stream sessions
      {Registry, keys: :unique, name: DecisionEngine.StreamRegistry},
      # Start the Registry for tracking conversation contexts
      {Registry, keys: :unique, name: DecisionEngine.ConversationRegistry},
      # Start the RuleConfig cache for domain configurations
      DecisionEngine.RuleConfig,
      # Start the HistoryManager for analysis history persistence
      DecisionEngine.HistoryManager,
      # Start the DescriptionGenerator for LLM-powered domain descriptions
      DecisionEngine.DescriptionGenerator,
      # Start the LLMConfigManager for centralized LLM configuration
      DecisionEngine.LLMConfigManager,
      # Start the ReqLLMConfigManager for ReqLLM-specific configuration management
      DecisionEngine.ReqLLMConfigManager,
      # Start the ReqLLMConnectionPool for connection pooling and resource management
      DecisionEngine.ReqLLMConnectionPool,
      # Start the ReqLLMRequestBatcher for request batching and prioritization
      DecisionEngine.ReqLLMRequestBatcher,
      # Start the ReqLLMResourceMonitor for resource constraint handling and monitoring
      DecisionEngine.ReqLLMResourceMonitor,
      # Start the ReqLLMFeatureFlags for migration control
      DecisionEngine.ReqLLMFeatureFlags,
      # Start the StreamingHandler for real-time LLM response streaming
      DecisionEngine.StreamingHandler,
      # Start the ReflectionConfig for reflection system configuration
      DecisionEngine.ReflectionConfig,
      # Start the ReflectionMetrics for reflection system metrics tracking
      DecisionEngine.ReflectionMetrics,
      # Start the ReflectionProgressTracker for reflection progress tracking
      DecisionEngine.ReflectionProgressTracker,
      # Start the ReflectionCancellationManager for reflection cancellation handling
      DecisionEngine.ReflectionCancellationManager,
      # Start the ReflectionQueueManager for concurrent reflection processing
      DecisionEngine.ReflectionQueueManager,
      # Start the StreamingPerformanceMonitor for streaming metrics tracking
      DecisionEngine.StreamingPerformanceMonitor,
      # Start the StreamingErrorHandler for enhanced error handling and recovery
      DecisionEngine.StreamingErrorHandler,
      # Start the StreamingBackpressureHandler for flow control and backpressure management
      DecisionEngine.StreamingBackpressureHandler,
      # Start the ReqLLMPerformanceMonitor for ReqLLM streaming performance monitoring
      DecisionEngine.ReqLLMPerformanceMonitor,
      # Start the ReqLLMContextPersistence for conversation context persistence
      DecisionEngine.ReqLLMContextPersistence,
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
