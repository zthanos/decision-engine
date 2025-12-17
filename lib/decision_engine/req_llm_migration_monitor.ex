# lib/decision_engine/req_llm_migration_monitor.ex
defmodule DecisionEngine.ReqLLMMigrationMonitor do
  @moduledoc """
  Monitors migration progress and implements automated rollback triggers.

  This module continuously monitors system health during migration and
  can automatically trigger rollbacks if performance degrades beyond
  acceptable thresholds.
  """

  use GenServer
  require Logger

  alias DecisionEngine.ReqLLMMigrationManager
  alias DecisionEngine.ReqLLMPerformanceMonitor
  alias DecisionEngine.ReqLLMFeatureFlags

  @monitoring_interval_ms 30_000  # Check every 30 seconds
  @alert_thresholds %{
    critical_error_rate: 0.10,      # 10% error rate triggers immediate rollback
    warning_error_rate: 0.05,       # 5% error rate triggers warning
    critical_latency_ratio: 3.0,    # 3x latency increase triggers rollback
    warning_latency_ratio: 2.0,     # 2x latency increase triggers warning
    min_requests_for_decision: 50   # Minimum requests before making rollback decisions
  }

  @rollback_conditions %{
    consecutive_critical_checks: 3,  # 3 consecutive critical checks trigger rollback
    consecutive_warning_checks: 10   # 10 consecutive warnings trigger rollback
  }

  # Client API

  @doc """
  Starts the migration monitor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets current monitoring status.
  """
  @spec get_monitoring_status() :: map()
  def get_monitoring_status() do
    GenServer.call(__MODULE__, :get_monitoring_status)
  end

  @doc """
  Enables automated rollback triggers.
  """
  @spec enable_auto_rollback() :: :ok
  def enable_auto_rollback() do
    GenServer.call(__MODULE__, :enable_auto_rollback)
  end

  @doc """
  Disables automated rollback triggers.
  """
  @spec disable_auto_rollback() :: :ok
  def disable_auto_rollback() do
    GenServer.call(__MODULE__, :disable_auto_rollback)
  end

  @doc """
  Forces a health check and returns results.
  """
  @spec force_health_check() :: map()
  def force_health_check() do
    GenServer.call(__MODULE__, :force_health_check)
  end

  @doc """
  Gets migration metrics history.
  """
  @spec get_metrics_history(integer()) :: {:ok, [map()]} | {:error, term()}
  def get_metrics_history(hours_back \\ 24) do
    GenServer.call(__MODULE__, {:get_metrics_history, hours_back})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Migration Monitor")

    state = %{
      auto_rollback_enabled: true,
      monitoring_active: true,
      health_history: [],
      alert_history: [],
      consecutive_warnings: 0,
      consecutive_criticals: 0,
      last_check_time: System.system_time(:second),
      rollback_triggered: false
    }

    # Schedule first health check
    schedule_health_check()

    Logger.info("Migration Monitor initialized with auto-rollback enabled")
    {:ok, state}
  end

  @impl true
  def handle_call(:get_monitoring_status, _from, state) do
    status = %{
      auto_rollback_enabled: state.auto_rollback_enabled,
      monitoring_active: state.monitoring_active,
      consecutive_warnings: state.consecutive_warnings,
      consecutive_criticals: state.consecutive_criticals,
      last_check_time: state.last_check_time,
      rollback_triggered: state.rollback_triggered,
      recent_alerts: Enum.take(state.alert_history, 10),
      health_checks_count: length(state.health_history)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:enable_auto_rollback, _from, state) do
    Logger.info("Enabling automated rollback triggers")
    new_state = %{state | auto_rollback_enabled: true}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:disable_auto_rollback, _from, state) do
    Logger.warning("Disabling automated rollback triggers")
    new_state = %{state | auto_rollback_enabled: false}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:force_health_check, _from, state) do
    {health_result, new_state} = perform_health_check(state)
    {:reply, health_result, new_state}
  end

  @impl true
  def handle_call({:get_metrics_history, hours_back}, _from, state) do
    cutoff_time = System.system_time(:second) - (hours_back * 3600)

    filtered_history = Enum.filter(state.health_history, fn check ->
      check.timestamp >= cutoff_time
    end)

    {:reply, {:ok, filtered_history}, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    {_health_result, new_state} = perform_health_check(state)

    # Schedule next health check
    schedule_health_check()

    {:noreply, new_state}
  end

  # Private Functions

  defp perform_health_check(state) do
    current_time = System.system_time(:second)

    Logger.debug("Performing migration health check")

    # Get current performance metrics
    case ReqLLMPerformanceMonitor.get_current_metrics() do
      {:ok, metrics} ->
        health_result = analyze_health_metrics(metrics, current_time)

        # Update state with health check results
        new_state = update_state_with_health_check(state, health_result, current_time)

        # Check if rollback should be triggered
        final_state = check_rollback_conditions(new_state, health_result)

        {health_result, final_state}

      {:error, reason} ->
        Logger.warning("Failed to get performance metrics for health check: #{inspect(reason)}")

        health_result = %{
          status: :unknown,
          error: reason,
          timestamp: current_time
        }

        new_state = %{state | last_check_time: current_time}
        {health_result, new_state}
    end
  end

  defp analyze_health_metrics(metrics, timestamp) do
    # Check if we have enough data to make decisions
    total_requests = metrics.total_requests

    if total_requests < @alert_thresholds.min_requests_for_decision do
      %{
        status: :insufficient_data,
        total_requests: total_requests,
        min_required: @alert_thresholds.min_requests_for_decision,
        timestamp: timestamp
      }
    else
      # Analyze key metrics
      error_rate = metrics.error_rate
      latency_ratio = metrics.latency_ratio
      streaming_success_rate = metrics.streaming_success_rate

      # Determine overall health status
      status = determine_health_status(error_rate, latency_ratio, streaming_success_rate)

      %{
        status: status,
        error_rate: error_rate,
        latency_ratio: latency_ratio,
        streaming_success_rate: streaming_success_rate,
        total_requests: total_requests,
        performance_improvement: metrics.performance_improvement,
        connection_pool_efficiency: metrics.connection_pool_efficiency,
        timestamp: timestamp,
        alerts: generate_alerts(error_rate, latency_ratio, streaming_success_rate)
      }
    end
  end

  defp determine_health_status(error_rate, latency_ratio, streaming_success_rate) do
    cond do
      error_rate >= @alert_thresholds.critical_error_rate ->
        :critical

      latency_ratio >= @alert_thresholds.critical_latency_ratio ->
        :critical

      streaming_success_rate < 0.8 ->  # Less than 80% streaming success
        :critical

      error_rate >= @alert_thresholds.warning_error_rate ->
        :warning

      latency_ratio >= @alert_thresholds.warning_latency_ratio ->
        :warning

      streaming_success_rate < 0.9 ->  # Less than 90% streaming success
        :warning

      true ->
        :healthy
    end
  end

  defp generate_alerts(error_rate, latency_ratio, streaming_success_rate) do
    alerts = []

    alerts = if error_rate >= @alert_thresholds.critical_error_rate do
      ["Critical error rate: #{Float.round(error_rate * 100, 2)}%" | alerts]
    else
      alerts
    end

    alerts = if error_rate >= @alert_thresholds.warning_error_rate do
      ["High error rate: #{Float.round(error_rate * 100, 2)}%" | alerts]
    else
      alerts
    end

    alerts = if latency_ratio >= @alert_thresholds.critical_latency_ratio do
      ["Critical latency increase: #{Float.round(latency_ratio, 2)}x" | alerts]
    else
      alerts
    end

    alerts = if latency_ratio >= @alert_thresholds.warning_latency_ratio do
      ["High latency increase: #{Float.round(latency_ratio, 2)}x" | alerts]
    else
      alerts
    end

    alerts = if streaming_success_rate < 0.8 do
      ["Low streaming success rate: #{Float.round(streaming_success_rate * 100, 2)}%" | alerts]
    else
      alerts
    end

    Enum.reverse(alerts)
  end

  defp update_state_with_health_check(state, health_result, current_time) do
    # Add to health history (keep last 1000 checks)
    updated_history = [health_result | state.health_history]
    |> Enum.take(1000)

    # Update consecutive counters based on status
    {new_warnings, new_criticals} = case health_result.status do
      :critical ->
        {0, state.consecutive_criticals + 1}

      :warning ->
        {state.consecutive_warnings + 1, 0}

      :healthy ->
        {0, 0}

      _ ->
        {state.consecutive_warnings, state.consecutive_criticals}
    end

    # Add alerts to alert history if any
    updated_alert_history = case Map.get(health_result, :alerts, []) do
      [] -> state.alert_history
      alerts ->
        alert_entries = Enum.map(alerts, fn alert ->
          %{
            message: alert,
            severity: health_result.status,
            timestamp: current_time
          }
        end)
        (alert_entries ++ state.alert_history) |> Enum.take(100)
    end

    %{state |
      health_history: updated_history,
      alert_history: updated_alert_history,
      consecutive_warnings: new_warnings,
      consecutive_criticals: new_criticals,
      last_check_time: current_time
    }
  end

  defp check_rollback_conditions(state, health_result) do
    if state.auto_rollback_enabled and not state.rollback_triggered do
      should_rollback = cond do
        state.consecutive_criticals >= @rollback_conditions.consecutive_critical_checks ->
          Logger.error("CRITICAL: #{state.consecutive_criticals} consecutive critical health checks - triggering automatic rollback")
          true

        state.consecutive_warnings >= @rollback_conditions.consecutive_warning_checks ->
          Logger.warning("WARNING: #{state.consecutive_warnings} consecutive warning health checks - triggering automatic rollback")
          true

        true ->
          false
      end

      if should_rollback do
        trigger_automatic_rollback(health_result)
        %{state | rollback_triggered: true}
      else
        state
      end
    else
      state
    end
  end

  defp trigger_automatic_rollback(health_result) do
    Logger.error("🚨 AUTOMATIC ROLLBACK TRIGGERED 🚨")
    Logger.error("Health status: #{health_result.status}")

    if Map.has_key?(health_result, :alerts) do
      Enum.each(health_result.alerts, fn alert ->
        Logger.error("Alert: #{alert}")
      end)
    end

    # Attempt rollback
    case ReqLLMMigrationManager.rollback_phase() do
      :ok ->
        Logger.info("✅ Automatic rollback completed successfully")

        # Optionally disable ReqLLM entirely for safety
        ReqLLMFeatureFlags.set_flag(:reqllm_enabled, false)
        Logger.info("🛡️  ReqLLM disabled for safety - manual intervention required")

      {:error, reason} ->
        Logger.error("❌ Automatic rollback failed: #{inspect(reason)}")
        Logger.error("🚨 MANUAL INTERVENTION REQUIRED 🚨")

        # Try to disable ReqLLM as emergency measure
        ReqLLMFeatureFlags.set_flag(:force_legacy, true)
        Logger.error("🚨 Emergency: Forced legacy mode enabled")
    end
  end

  defp schedule_health_check() do
    Process.send_after(self(), :health_check, @monitoring_interval_ms)
  end
end
