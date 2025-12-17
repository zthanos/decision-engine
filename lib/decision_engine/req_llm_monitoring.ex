# lib/decision_engine/req_llm_monitoring.ex
defmodule DecisionEngine.ReqLLMMonitoring do
  @moduledoc """
  Centralized monitoring and logging initialization for ReqLLM integration.

  This module provides a unified interface to initialize and configure all
  monitoring, logging, and correlation tracking systems for ReqLLM.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation
  alias DecisionEngine.ReqLLMErrorContext

  @doc """
  Initializes all ReqLLM monitoring systems.

  ## Parameters
  - config: Optional configuration map for monitoring systems

  ## Returns
  - :ok on successful initialization
  - {:error, reason} on failure
  """
  @spec init(map()) :: :ok | {:error, term()}
  def init(config \\ %{}) do
    try do
      # Initialize correlation tracking
      :ok = ReqLLMCorrelation.init()

      # Initialize error context capture
      :ok = ReqLLMErrorContext.init()

      # Configure logging system
      logging_config = Map.get(config, :logging, %{})
      :ok = ReqLLMLogger.configure_logging(logging_config)

      # Start cleanup processes
      start_cleanup_processes(config)

      Logger.info("ReqLLM monitoring systems initialized successfully")
      :ok

    rescue
      error ->
        Logger.error("Failed to initialize ReqLLM monitoring systems: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Gets comprehensive monitoring statistics.

  ## Returns
  - Map containing all monitoring statistics
  """
  @spec get_monitoring_stats() :: map()
  def get_monitoring_stats do
    %{
      correlation_stats: ReqLLMCorrelation.get_correlation_statistics(),
      error_stats: ReqLLMErrorContext.get_error_statistics(),
      error_patterns: ReqLLMErrorContext.analyze_error_patterns(),
      logging_config: ReqLLMLogger.get_logging_config(),
      system_info: get_system_info()
    }
  end

  @doc """
  Performs cleanup of expired monitoring data.

  ## Returns
  - Map with cleanup results
  """
  @spec cleanup_monitoring_data() :: map()
  def cleanup_monitoring_data do
    {:ok, correlation_cleaned} = ReqLLMCorrelation.cleanup_expired_correlations()
    {:ok, error_context_cleaned} = ReqLLMErrorContext.cleanup_expired_contexts()

    %{
      correlations_cleaned: correlation_cleaned,
      error_contexts_cleaned: error_context_cleaned,
      cleanup_time: System.system_time(:millisecond)
    }
  end

  @doc """
  Configures monitoring systems with new settings.

  ## Parameters
  - config: Configuration map with monitoring settings

  ## Returns
  - :ok on success
  """
  @spec configure_monitoring(map()) :: :ok
  def configure_monitoring(config) do
    # Update logging configuration
    if Map.has_key?(config, :logging) do
      ReqLLMLogger.configure_logging(config.logging)
    end

    Logger.info("ReqLLM monitoring configuration updated", %{
      event: "reqllm_monitoring_config_updated",
      config_keys: Map.keys(config),
      timestamp: System.system_time(:millisecond)
    })

    :ok
  end

  @doc """
  Gets health status of monitoring systems.

  ## Returns
  - Map with health status information
  """
  @spec get_health_status() :: map()
  def get_health_status do
    %{
      correlation_system: check_correlation_system_health(),
      error_context_system: check_error_context_system_health(),
      logging_system: check_logging_system_health(),
      overall_status: :healthy,
      last_check: System.system_time(:millisecond)
    }
  end

  # Private Functions

  defp start_cleanup_processes(config) do
    # Start periodic cleanup process
    cleanup_interval = Map.get(config, :cleanup_interval_ms, 3_600_000)  # 1 hour default

    spawn(fn ->
      cleanup_loop(cleanup_interval)
    end)

    :ok
  end

  defp cleanup_loop(interval_ms) do
    Process.sleep(interval_ms)

    try do
      cleanup_results = cleanup_monitoring_data()
      Logger.debug("Periodic monitoring cleanup completed", %{
        event: "reqllm_monitoring_cleanup",
        results: cleanup_results
      })
    rescue
      error ->
        Logger.warning("Monitoring cleanup failed: #{inspect(error)}")
    end

    cleanup_loop(interval_ms)
  end

  defp get_system_info do
    %{
      node: Node.self(),
      uptime_ms: :erlang.statistics(:wall_clock) |> elem(0),
      memory_usage: :erlang.memory(),
      process_count: :erlang.system_info(:process_count),
      system_version: :erlang.system_info(:system_version) |> to_string() |> String.trim()
    }
  end

  defp check_correlation_system_health do
    try do
      # Try to generate a correlation ID to test the system
      _test_id = ReqLLMCorrelation.generate_correlation_id("health_check")
      :healthy
    rescue
      _ -> :unhealthy
    end
  end

  defp check_error_context_system_health do
    try do
      # Try to get error statistics to test the system
      _stats = ReqLLMErrorContext.get_error_statistics(60_000)
      :healthy
    rescue
      _ -> :unhealthy
    end
  end

  defp check_logging_system_health do
    try do
      # Try to get logging configuration to test the system
      _config = ReqLLMLogger.get_logging_config()
      :healthy
    rescue
      _ -> :unhealthy
    end
  end
end
