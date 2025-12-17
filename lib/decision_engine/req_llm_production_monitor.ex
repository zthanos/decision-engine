# lib/decision_engine/req_llm_production_monitor.ex
defmodule DecisionEngine.ReqLLMProductionMonitor do
  @moduledoc """
  Production monitoring and alerting for ReqLLM integration.

  This module provides comprehensive monitoring, health checks, and alerting
  capabilities for production ReqLLM deployments.
  """

  use GenServer
  require Logger
  alias DecisionEngine.ReqLLMPerformanceMonitor
  alias DecisionEngine.ReqLLMConnectionPool

  @check_interval_ms 30_000  # 30 seconds
  @alert_cooldown_ms 900_000  # 15 minutes between similar alerts

  # Client API

  @doc """
  Starts the production monitor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets current system health status.
  """
  @spec get_health_status() :: {:ok, map()} | {:error, term()}
  def get_health_status() do
    GenServer.call(__MODULE__, :get_health_status)
  end

  @doc """
  Gets detailed monitoring metrics.
  """
  @spec get_monitoring_metrics() :: {:ok, map()} | {:error, term()}
  def get_monitoring_metrics() do
    GenServer.call(__MODULE__, :get_monitoring_metrics)
  end

  @doc """
  Configures alerting thresholds.
  """
  @spec configure_alerting(map()) :: :ok
  def configure_alerting(thresholds) do
    GenServer.cast(__MODULE__, {:configure_alerting, thresholds})
  end

  @doc """
  Triggers a manual health check.
  """
  @spec trigger_health_check() :: {:ok, map()} | {:error, term()}
  def trigger_health_check() do
    GenServer.call(__MODULE__, :trigger_health_check)
  end

  @doc """
  Gets alert history.
  """
  @spec get_alert_history(integer()) :: {:ok, list()} | {:error, term()}
  def get_alert_history(hours_back \\ 24) do
    GenServer.call(__MODULE__, {:get_alert_history, hours_back})
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting ReqLLM Production Monitor")

    # Default monitoring configuration
    default_config = %{
      performance_thresholds: %{
        latency: %{
          warning_ms: 4000,
          critical_ms: 5000,
          measurement_window_minutes: 5
        },
        success_rate: %{
          warning_threshold: 0.995,
          critical_threshold: 0.99,
          measurement_window_minutes: 10
        },
        error_rate: %{
          warning_threshold: 0.008,
          critical_threshold: 0.01,
          measurement_window_minutes: 5
        },
        throughput: %{
          min_requests_per_second: 1.0,
          measurement_window_minutes: 15
        }
      },
      alerting: %{
        channels: [:log, :email],
        escalation_delay_minutes: 5,
        alert_frequency_minutes: 15,
        recovery_notification: true
      },
      health_checks: %{
        enabled: true,
        check_interval_seconds: 30,
        timeout_seconds: 10,
        providers_to_check: [:openai, :anthropic]
      }
    }

    config = Map.merge(default_config, Map.new(opts))

    state = %{
      config: config,
      last_health_check: nil,
      alert_history: [],
      last_alerts: %{},  # Track last alert time by type
      system_status: :unknown,
      current_metrics: %{}
    }

    # Schedule first health check
    schedule_health_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_health_status, _from, state) do
    health_status = %{
      system_status: state.system_status,
      last_check: state.last_health_check,
      current_metrics: state.current_metrics,
      alert_count_24h: count_recent_alerts(state.alert_history, 24),
      uptime_percentage: calculate_uptime_percentage(state.alert_history)
    }

    {:reply, {:ok, health_status}, state}
  end

  @impl true
  def handle_call(:get_monitoring_metrics, _from, state) do
    case ReqLLMPerformanceMonitor.get_current_metrics() do
      {:ok, performance_metrics} ->
        # Combine with connection pool metrics
        connection_metrics = get_connection_pool_metrics()

        monitoring_metrics = %{
          performance: performance_metrics,
          connections: connection_metrics,
          system_health: %{
            status: state.system_status,
            last_check: state.last_health_check,
            check_interval_seconds: state.config.health_checks.check_interval_seconds
          },
          alerting: %{
            active_alerts: get_active_alerts(state.alert_history),
            alert_count_24h: count_recent_alerts(state.alert_history, 24),
            last_alert: get_last_alert(state.alert_history)
          }
        }

        {:reply, {:ok, monitoring_metrics}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:trigger_health_check, _from, state) do
    {health_status, new_state} = perform_health_check(state)
    {:reply, {:ok, health_status}, new_state}
  end

  @impl true
  def handle_call({:get_alert_history, hours_back}, _from, state) do
    cutoff_time = System.system_time(:second) - (hours_back * 3600)

    recent_alerts = Enum.filter(state.alert_history, fn alert ->
      alert.timestamp >= cutoff_time
    end)

    {:reply, {:ok, recent_alerts}, state}
  end

  @impl true
  def handle_cast({:configure_alerting, thresholds}, state) do
    updated_config = put_in(state.config, [:performance_thresholds], thresholds)
    new_state = %{state | config: updated_config}

    Logger.info("Updated alerting thresholds: #{inspect(thresholds)}")
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:health_check, state) do
    {_health_status, new_state} = perform_health_check(state)

    # Schedule next health check
    schedule_health_check()

    {:noreply, new_state}
  end

  # Private Functions

  defp perform_health_check(state) do
    Logger.debug("Performing ReqLLM health check")

    check_start_time = System.system_time(:second)

    # Get current performance metrics
    performance_result = case ReqLLMPerformanceMonitor.get_current_metrics() do
      {:ok, metrics} -> {:ok, metrics}
      {:error, reason} ->
        Logger.warning("Failed to get performance metrics: #{inspect(reason)}")
        {:error, reason}
    end

    # Check connection pool health
    connection_health = check_connection_pool_health()

    # Check provider connectivity
    provider_health = check_provider_connectivity(state.config.health_checks.providers_to_check)

    # Determine overall system status
    overall_status = determine_system_status(performance_result, connection_health, provider_health)

    # Check for threshold violations and generate alerts
    alerts = case performance_result do
      {:ok, metrics} ->
        check_performance_thresholds(metrics, state.config.performance_thresholds)
      {:error, _} ->
        [create_alert(:critical, :metrics_unavailable, "Performance metrics unavailable", %{})]
    end

    # Process alerts (with cooldown)
    {new_alerts, updated_last_alerts} = process_alerts(alerts, state.last_alerts)

    # Update state
    health_status = %{
      status: overall_status,
      timestamp: check_start_time,
      performance_metrics: performance_result,
      connection_health: connection_health,
      provider_health: provider_health,
      alerts_generated: length(new_alerts)
    }

    updated_state = %{state |
      last_health_check: check_start_time,
      system_status: overall_status,
      current_metrics: case performance_result do
        {:ok, metrics} -> metrics
        {:error, _} -> %{}
      end,
      alert_history: new_alerts ++ state.alert_history,
      last_alerts: updated_last_alerts
    }

    # Send alerts if any
    if not Enum.empty?(new_alerts) do
      send_alerts(new_alerts, state.config.alerting)
    end

    {health_status, updated_state}
  end

  defp check_connection_pool_health() do
    try do
      # Check each provider's connection pool
      providers = [:openai, :anthropic, :ollama]

      pool_statuses = for provider <- providers do
        try do
          case ReqLLMConnectionPool.get_pool_status(provider) do
            {:ok, status} ->
              health = cond do
                status.available_connections == 0 -> :critical
                status.available_connections < status.pool_size * 0.2 -> :warning
                true -> :healthy
              end

              {provider, %{
                status: health,
                available_connections: status.available_connections,
                total_connections: status.pool_size,
                utilization: (status.pool_size - status.available_connections) / status.pool_size
              }}

            {:error, :pool_not_found} ->
              {provider, %{status: :not_configured, message: "Pool not configured"}}

            {:error, reason} ->
              {provider, %{status: :error, message: inspect(reason)}}
          end
        rescue
          UndefinedFunctionError ->
            {provider, %{status: :not_available, message: "Connection pool module not available"}}
          error ->
            {provider, %{status: :error, message: inspect(error)}}
        end
      end

      statuses = Enum.map(pool_statuses, fn {_, status} -> status.status end)

      overall_pool_health = cond do
        :critical in statuses -> :critical
        :warning in statuses -> :warning
        :error in statuses -> :degraded
        true -> :healthy
      end

      %{
        overall_status: overall_pool_health,
        providers: Map.new(pool_statuses)
      }
    rescue
      error ->
        Logger.error("Connection pool health check failed: #{inspect(error)}")
        %{overall_status: :error, error: inspect(error)}
    end
  end

  defp check_provider_connectivity(providers) do
    connectivity_results = for provider <- providers do
      result = case provider do
        :openai -> test_openai_connectivity()
        :anthropic -> test_anthropic_connectivity()
        :ollama -> test_ollama_connectivity()
        _ -> {:error, "Unknown provider"}
      end

      {provider, result}
    end

    results = Enum.map(connectivity_results, fn {_, result} -> elem(result, 0) end)

    overall_connectivity = cond do
      :error in results -> :degraded
      :timeout in results -> :warning
      true -> :healthy
    end

    %{
      overall_status: overall_connectivity,
      providers: Map.new(connectivity_results)
    }
  end

  defp test_openai_connectivity() do
    # Simple connectivity test - just check if we can reach the API
    try do
      case HTTPoison.get("https://api.openai.com/v1/models", [], [timeout: 5000, recv_timeout: 5000]) do
        {:ok, %{status_code: status}} when status in [200, 401] ->
          {:ok, "API reachable"}
        {:ok, %{status_code: status}} ->
          {:warning, "API returned status #{status}"}
        {:error, %{reason: :timeout}} ->
          {:timeout, "Connection timeout"}
        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    rescue
      _ -> {:error, "HTTPoison not available, skipping connectivity test"}
    end
  end

  defp test_anthropic_connectivity() do
    try do
      case HTTPoison.get("https://api.anthropic.com/v1/messages", [], [timeout: 5000, recv_timeout: 5000]) do
        {:ok, %{status_code: status}} when status in [200, 400, 401] ->
          {:ok, "API reachable"}
        {:ok, %{status_code: status}} ->
          {:warning, "API returned status #{status}"}
        {:error, %{reason: :timeout}} ->
          {:timeout, "Connection timeout"}
        {:error, reason} ->
          {:error, "Connection failed: #{inspect(reason)}"}
      end
    rescue
      _ -> {:error, "HTTPoison not available, skipping connectivity test"}
    end
  end

  defp test_ollama_connectivity() do
    # Ollama is typically local, so test localhost
    try do
      case HTTPoison.get("http://localhost:11434/api/tags", [], [timeout: 3000, recv_timeout: 3000]) do
        {:ok, %{status_code: 200}} ->
          {:ok, "Ollama API reachable"}
        {:ok, %{status_code: status}} ->
          {:warning, "Ollama API returned status #{status}"}
        {:error, %{reason: :timeout}} ->
          {:timeout, "Ollama connection timeout"}
        {:error, reason} ->
          {:error, "Ollama connection failed: #{inspect(reason)}"}
      end
    rescue
      _ -> {:error, "HTTPoison not available, skipping Ollama test"}
    end
  end

  defp determine_system_status(performance_result, connection_health, provider_health) do
    case {performance_result, connection_health.overall_status, provider_health.overall_status} do
      {{:error, _}, _, _} -> :critical
      {_, :critical, _} -> :critical
      {_, _, :degraded} -> :degraded
      {_, :warning, _} -> :warning
      {_, _, :warning} -> :warning
      {{:ok, _}, :healthy, :healthy} -> :healthy
      _ -> :unknown
    end
  end

  defp check_performance_thresholds(metrics, thresholds) do
    alerts = []

    # Check latency thresholds
    alerts = case get_in(metrics, [:reqllm, :latency_stats, :avg]) do
      nil -> alerts
      avg_latency ->
        cond do
          avg_latency >= thresholds.latency.critical_ms ->
            [create_alert(:critical, :high_latency, "Average latency exceeds critical threshold", %{
              current_latency: avg_latency,
              threshold: thresholds.latency.critical_ms
            }) | alerts]

          avg_latency >= thresholds.latency.warning_ms ->
            [create_alert(:warning, :high_latency, "Average latency exceeds warning threshold", %{
              current_latency: avg_latency,
              threshold: thresholds.latency.warning_ms
            }) | alerts]

          true -> alerts
        end
    end

    # Check success rate thresholds
    alerts = case get_in(metrics, [:reqllm, :success_rate]) do
      nil -> alerts
      success_rate ->
        cond do
          success_rate <= thresholds.success_rate.critical_threshold ->
            [create_alert(:critical, :low_success_rate, "Success rate below critical threshold", %{
              current_rate: success_rate,
              threshold: thresholds.success_rate.critical_threshold
            }) | alerts]

          success_rate <= thresholds.success_rate.warning_threshold ->
            [create_alert(:warning, :low_success_rate, "Success rate below warning threshold", %{
              current_rate: success_rate,
              threshold: thresholds.success_rate.warning_threshold
            }) | alerts]

          true -> alerts
        end
    end

    # Check error rate thresholds
    alerts = case get_in(metrics, [:reqllm, :error_rate]) do
      nil -> alerts
      error_rate ->
        cond do
          error_rate >= thresholds.error_rate.critical_threshold ->
            [create_alert(:critical, :high_error_rate, "Error rate exceeds critical threshold", %{
              current_rate: error_rate,
              threshold: thresholds.error_rate.critical_threshold
            }) | alerts]

          error_rate >= thresholds.error_rate.warning_threshold ->
            [create_alert(:warning, :high_error_rate, "Error rate exceeds warning threshold", %{
              current_rate: error_rate,
              threshold: thresholds.error_rate.warning_threshold
            }) | alerts]

          true -> alerts
        end
    end

    alerts
  end

  defp create_alert(severity, type, message, metadata) do
    %{
      id: generate_alert_id(),
      severity: severity,
      type: type,
      message: message,
      metadata: metadata,
      timestamp: System.system_time(:second),
      resolved: false
    }
  end

  defp generate_alert_id() do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp process_alerts(alerts, last_alerts) do
    current_time = System.system_time(:second)

    # Filter out alerts that are in cooldown
    new_alerts = Enum.filter(alerts, fn alert ->
      alert_key = {alert.severity, alert.type}
      last_alert_time = Map.get(last_alerts, alert_key, 0)

      current_time - last_alert_time >= (@alert_cooldown_ms / 1000)
    end)

    # Update last alert times
    updated_last_alerts = Enum.reduce(new_alerts, last_alerts, fn alert, acc ->
      alert_key = {alert.severity, alert.type}
      Map.put(acc, alert_key, current_time)
    end)

    {new_alerts, updated_last_alerts}
  end

  defp send_alerts(alerts, alerting_config) do
    channels = Map.get(alerting_config, :channels, [:log])

    for alert <- alerts do
      for channel <- channels do
        send_alert_to_channel(alert, channel)
      end
    end
  end

  defp send_alert_to_channel(alert, :log) do
    log_level = case alert.severity do
      :critical -> :error
      :warning -> :warning
      _ -> :info
    end

    Logger.log(log_level, "ReqLLM Alert [#{alert.severity}] #{alert.type}: #{alert.message}")

    if not Enum.empty?(alert.metadata) do
      Logger.log(log_level, "Alert metadata: #{inspect(alert.metadata)}")
    end
  end

  defp send_alert_to_channel(alert, :email) do
    # Placeholder for email alerting
    # In a real implementation, this would integrate with an email service
    Logger.info("Email alert would be sent: #{alert.message}")
  end

  defp send_alert_to_channel(alert, channel) do
    Logger.warning("Unknown alert channel: #{channel} for alert: #{alert.message}")
  end

  defp get_connection_pool_metrics() do
    providers = [:openai, :anthropic, :ollama]

    pool_metrics = for provider <- providers do
      try do
        case ReqLLMConnectionPool.get_pool_status(provider) do
          {:ok, status} ->
            {provider, %{
              pool_size: status.pool_size,
              available_connections: status.available_connections,
              checked_out_connections: status.pool_size - status.available_connections,
              utilization_percent: ((status.pool_size - status.available_connections) / status.pool_size) * 100
            }}

          {:error, :pool_not_found} ->
            {provider, %{status: :not_configured}}

          {:error, reason} ->
            {provider, %{status: :error, reason: inspect(reason)}}
        end
      rescue
        UndefinedFunctionError ->
          {provider, %{status: :not_available, message: "Connection pool module not available"}}
        error ->
          {provider, %{status: :error, reason: inspect(error)}}
      end
    end

    Map.new(pool_metrics)
  end

  defp count_recent_alerts(alert_history, hours_back) do
    cutoff_time = System.system_time(:second) - (hours_back * 3600)

    Enum.count(alert_history, fn alert ->
      alert.timestamp >= cutoff_time
    end)
  end

  defp calculate_uptime_percentage(alert_history) do
    # Simple uptime calculation based on critical alerts in the last 24 hours
    hours_back = 24
    cutoff_time = System.system_time(:second) - (hours_back * 3600)

    critical_alerts = Enum.filter(alert_history, fn alert ->
      alert.timestamp >= cutoff_time and alert.severity == :critical
    end)

    # Assume each critical alert represents 5 minutes of downtime
    downtime_minutes = length(critical_alerts) * 5
    total_minutes = hours_back * 60

    uptime_minutes = max(0, total_minutes - downtime_minutes)
    (uptime_minutes / total_minutes) * 100
  end

  defp get_active_alerts(alert_history) do
    # Get unresolved alerts from the last hour
    cutoff_time = System.system_time(:second) - 3600

    Enum.filter(alert_history, fn alert ->
      alert.timestamp >= cutoff_time and not alert.resolved
    end)
  end

  defp get_last_alert(alert_history) do
    case alert_history do
      [] -> nil
      [latest | _] -> latest
    end
  end

  defp schedule_health_check() do
    Process.send_after(self(), :health_check, @check_interval_ms)
  end
end
