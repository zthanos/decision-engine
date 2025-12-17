defmodule DecisionEngine.ReqLLMPerformanceMonitor do
  @moduledoc """
  Real-time streaming performance monitoring and metrics collection for ReqLLM.

  This module provides comprehensive performance monitoring including:
  - Real-time streaming metrics collection
  - Streaming health monitoring and alerting
  - Performance benchmarking and comparison
  - Historical performance tracking
  - Automated performance analysis and reporting
  """

  use GenServer
  require Logger

  @typedoc """
  Performance metrics for a streaming session.
  """
  @type session_metrics :: %{
    session_id: String.t(),
    provider: atom(),
    model: String.t(),
    start_time: integer(),
    end_time: integer() | nil,
    status: :active | :completed | :error | :cancelled,
    chunks_received: integer(),
    bytes_received: integer(),
    latency_metrics: %{
      first_chunk_latency_ms: float(),
      average_chunk_latency_ms: float(),
      max_chunk_latency_ms: float(),
      min_chunk_latency_ms: float(),
      p95_chunk_latency_ms: float()
    },
    throughput_metrics: %{
      chunks_per_second: float(),
      bytes_per_second: float(),
      effective_throughput_bps: float()
    },
    quality_metrics: %{
      error_count: integer(),
      reconnection_count: integer(),
      chunk_loss_count: integer(),
      out_of_order_chunks: integer(),
      success_rate: float()
    },
    resource_metrics: %{
      memory_usage_bytes: integer(),
      cpu_usage_percent: float(),
      network_usage_bytes: integer()
    }
  }

  # Configuration constants
  @metrics_retention_hours 24
  @alert_thresholds %{
    high_latency_ms: 5000,
    low_throughput_bps: 1000,
    high_error_rate: 0.1,
    memory_limit_mb: 100
  }

  ## Public API

  @doc """
  Starts the performance monitoring server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  @doc """
  Records the start of a streaming session.

  ## Parameters
  - session_id: Unique identifier for the streaming session
  - provider: LLM provider being used
  - model: Model being used (optional)

  ## Returns
  - :ok
  """
  @spec record_session_start(String.t(), atom(), String.t()) :: :ok
  def record_session_start(session_id, provider, model \\ "unknown") do
    GenServer.cast(__MODULE__, {:session_start, session_id, provider, model})
  end

  @doc """
  Records the end of a streaming session.

  ## Parameters
  - session_id: The session that ended
  - status: Final status (:completed, :error, :cancelled)

  ## Returns
  - :ok
  """
  @spec record_session_end(String.t(), atom()) :: :ok
  def record_session_end(session_id, status \\ :completed) do
    GenServer.cast(__MODULE__, {:session_end, session_id, status})
  end

  @doc """
  Records chunk latency for performance tracking.

  ## Parameters
  - session_id: The streaming session
  - provider: LLM provider
  - chunk_size: Size of the chunk in bytes
  - latency_us: Processing latency in microseconds

  ## Returns
  - :ok
  """
  @spec record_chunk_latency(String.t(), atom(), integer(), integer()) :: :ok
  def record_chunk_latency(session_id, provider, chunk_size, latency_us) do
    GenServer.cast(__MODULE__, {:chunk_latency, session_id, provider, chunk_size, latency_us})
  end

  @doc """
  Records an error for performance tracking.

  ## Parameters
  - session_id: The streaming session
  - error_type: Type of error (:timeout, :network, :processing, etc.)
  - provider: LLM provider

  ## Returns
  - :ok
  """
  @spec record_error(String.t(), atom(), atom()) :: :ok
  def record_error(session_id, error_type, provider) do
    GenServer.cast(__MODULE__, {:error, session_id, error_type, provider})
  end

  @doc """
  Records a reconnection event.

  ## Parameters
  - session_id: The streaming session
  - provider: LLM provider
  - reconnection_time_ms: Time taken to reconnect

  ## Returns
  - :ok
  """
  @spec record_reconnection(String.t(), atom(), integer()) :: :ok
  def record_reconnection(session_id, provider, reconnection_time_ms) do
    GenServer.cast(__MODULE__, {:reconnection, session_id, provider, reconnection_time_ms})
  end

  @doc """
  Gets current performance metrics for a session.

  ## Parameters
  - session_id: The session to get metrics for

  ## Returns
  - {:ok, metrics} with current session metrics
  - {:error, :not_found} if session doesn't exist
  """
  @spec get_session_metrics(String.t()) :: {:ok, session_metrics()} | {:error, :not_found}
  def get_session_metrics(session_id) do
    GenServer.call(__MODULE__, {:get_session_metrics, session_id})
  end

  @doc """
  Gets aggregated performance metrics across all sessions.

  ## Parameters
  - time_window_hours: Time window for aggregation (default: 1 hour)

  ## Returns
  - Map with aggregated performance metrics
  """
  @spec get_aggregated_metrics(integer()) :: map()
  def get_aggregated_metrics(time_window_hours \\ 1) do
    GenServer.call(__MODULE__, {:get_aggregated_metrics, time_window_hours})
  end

  @doc """
  Gets performance comparison between providers.

  ## Parameters
  - time_window_hours: Time window for comparison (default: 1 hour)

  ## Returns
  - Map with provider comparison metrics
  """
  @spec get_provider_comparison(integer()) :: map()
  def get_provider_comparison(time_window_hours \\ 1) do
    GenServer.call(__MODULE__, {:get_provider_comparison, time_window_hours})
  end

  @doc """
  Gets current performance alerts.

  ## Returns
  - List of active performance alerts
  """
  @spec get_performance_alerts() :: [map()]
  def get_performance_alerts do
    GenServer.call(__MODULE__, :get_performance_alerts)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize ETS tables for metrics storage
    :ets.new(:session_metrics, [:named_table, :public, :set])
    :ets.new(:chunk_latencies, [:named_table, :public, :bag])
    :ets.new(:performance_alerts, [:named_table, :public, :set])

    # Schedule periodic cleanup and analysis
    schedule_cleanup()
    schedule_analysis()

    state = %{
      active_sessions: %{},
      alert_thresholds: @alert_thresholds,
      last_cleanup: System.system_time(:second),
      last_analysis: System.system_time(:second)
    }

    Logger.info("ReqLLMPerformanceMonitor started")

    {:ok, state}
  end

  @impl true
  def handle_cast({:session_start, session_id, provider, model}, state) do
    current_time = System.monotonic_time(:microsecond)

    session_metrics = %{
      session_id: session_id,
      provider: provider,
      model: model,
      start_time: current_time,
      end_time: nil,
      status: :active,
      chunks_received: 0,
      bytes_received: 0,
      latency_metrics: %{
        first_chunk_latency_ms: nil,
        average_chunk_latency_ms: 0.0,
        max_chunk_latency_ms: 0.0,
        min_chunk_latency_ms: Float.max_finite(),
        p95_chunk_latency_ms: 0.0
      },
      throughput_metrics: %{
        chunks_per_second: 0.0,
        bytes_per_second: 0.0,
        effective_throughput_bps: 0.0
      },
      quality_metrics: %{
        error_count: 0,
        reconnection_count: 0,
        chunk_loss_count: 0,
        out_of_order_chunks: 0,
        success_rate: 1.0
      },
      resource_metrics: %{
        memory_usage_bytes: 0,
        cpu_usage_percent: 0.0,
        network_usage_bytes: 0
      }
    }

    # Store in ETS
    :ets.insert(:session_metrics, {session_id, session_metrics})

    # Update active sessions
    updated_active_sessions = Map.put(state.active_sessions, session_id, current_time)

    Logger.debug("Performance monitoring started for session #{session_id} (#{provider}/#{model})")

    {:noreply, %{state | active_sessions: updated_active_sessions}}
  end

  @impl true
  def handle_cast({:session_end, session_id, status}, state) do
    current_time = System.monotonic_time(:microsecond)

    case :ets.lookup(:session_metrics, session_id) do
      [{^session_id, session_metrics}] ->
        # Update session with end time and status
        updated_metrics = %{session_metrics |
          end_time: current_time,
          status: status
        }

        # Calculate final metrics
        final_metrics = calculate_final_session_metrics(updated_metrics)

        # Update ETS
        :ets.insert(:session_metrics, {session_id, final_metrics})

        # Remove from active sessions
        updated_active_sessions = Map.delete(state.active_sessions, session_id)

        # Check for performance alerts
        check_session_alerts(final_metrics, state.alert_thresholds)

        Logger.info("Performance monitoring ended for session #{session_id}: #{status}")

        {:noreply, %{state | active_sessions: updated_active_sessions}}

      [] ->
        Logger.warning("Attempted to end monitoring for unknown session: #{session_id}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:chunk_latency, session_id, provider, chunk_size, latency_us}, state) do
    current_time = System.system_time(:second)
    latency_ms = latency_us / 1000

    # Store latency data
    :ets.insert(:chunk_latencies, {session_id, {current_time, latency_ms, chunk_size, provider}})

    # Update session metrics
    case :ets.lookup(:session_metrics, session_id) do
      [{^session_id, session_metrics}] ->
        updated_metrics = update_session_with_chunk(session_metrics, chunk_size, latency_ms)
        :ets.insert(:session_metrics, {session_id, updated_metrics})

        # Check for latency alerts
        if latency_ms > state.alert_thresholds.high_latency_ms do
          create_alert(:high_latency, session_id, %{
            latency_ms: latency_ms,
            threshold_ms: state.alert_thresholds.high_latency_ms,
            provider: provider
          })
        end

      [] ->
        Logger.warning("Received chunk latency for unknown session: #{session_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:error, session_id, error_type, provider}, state) do
    # Update session error count
    case :ets.lookup(:session_metrics, session_id) do
      [{^session_id, session_metrics}] ->
        updated_quality = %{session_metrics.quality_metrics |
          error_count: session_metrics.quality_metrics.error_count + 1
        }

        updated_metrics = %{session_metrics | quality_metrics: updated_quality}
        :ets.insert(:session_metrics, {session_id, updated_metrics})

        # Calculate error rate and check for alerts
        error_rate = updated_quality.error_count / max(session_metrics.chunks_received, 1)
        if error_rate > state.alert_thresholds.high_error_rate do
          create_alert(:high_error_rate, session_id, %{
            error_rate: error_rate,
            error_type: error_type,
            provider: provider
          })
        end

      [] ->
        Logger.warning("Received error for unknown session: #{session_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reconnection, session_id, provider, reconnection_time_ms}, state) do
    # Update session reconnection count
    case :ets.lookup(:session_metrics, session_id) do
      [{^session_id, session_metrics}] ->
        updated_quality = %{session_metrics.quality_metrics |
          reconnection_count: session_metrics.quality_metrics.reconnection_count + 1
        }

        updated_metrics = %{session_metrics | quality_metrics: updated_quality}
        :ets.insert(:session_metrics, {session_id, updated_metrics})

        Logger.info("Recorded reconnection for session #{session_id}: #{reconnection_time_ms}ms (#{provider})")

      [] ->
        Logger.warning("Received reconnection for unknown session: #{session_id}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_session_metrics, session_id}, _from, state) do
    case :ets.lookup(:session_metrics, session_id) do
      [{^session_id, session_metrics}] ->
        {:reply, {:ok, session_metrics}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_aggregated_metrics, time_window_hours}, _from, state) do
    aggregated_metrics = calculate_aggregated_metrics(time_window_hours)
    {:reply, aggregated_metrics, state}
  end

  @impl true
  def handle_call({:get_provider_comparison, time_window_hours}, _from, state) do
    comparison_metrics = calculate_provider_comparison(time_window_hours)
    {:reply, comparison_metrics, state}
  end

  @impl true
  def handle_call(:get_performance_alerts, _from, state) do
    alerts = :ets.tab2list(:performance_alerts)
    |> Enum.map(fn {_id, alert} -> alert end)
    |> Enum.sort_by(& &1.timestamp, :desc)

    {:reply, alerts, state}
  end

  @impl true
  def handle_info(:cleanup_metrics, state) do
    perform_cleanup()
    schedule_cleanup()
    {:noreply, %{state | last_cleanup: System.system_time(:second)}}
  end

  @impl true
  def handle_info(:analyze_performance, state) do
    perform_analysis(state.alert_thresholds)
    schedule_analysis()
    {:noreply, %{state | last_analysis: System.system_time(:second)}}
  end

  ## Private Functions

  # Update session metrics with new chunk data
  defp update_session_with_chunk(session_metrics, chunk_size, latency_ms) do
    current_time = System.monotonic_time(:microsecond)

    # Update basic counters
    new_chunks_received = session_metrics.chunks_received + 1
    new_bytes_received = session_metrics.bytes_received + chunk_size

    # Update latency metrics
    updated_latency = update_latency_metrics(session_metrics.latency_metrics, latency_ms, new_chunks_received)

    # Update throughput metrics
    duration_seconds = (current_time - session_metrics.start_time) / 1_000_000
    updated_throughput = %{
      chunks_per_second: if(duration_seconds > 0, do: new_chunks_received / duration_seconds, else: 0.0),
      bytes_per_second: if(duration_seconds > 0, do: new_bytes_received / duration_seconds, else: 0.0),
      effective_throughput_bps: if(duration_seconds > 0, do: new_bytes_received * 8 / duration_seconds, else: 0.0)
    }

    %{session_metrics |
      chunks_received: new_chunks_received,
      bytes_received: new_bytes_received,
      latency_metrics: updated_latency,
      throughput_metrics: updated_throughput
    }
  end

  # Update latency metrics with new latency measurement
  defp update_latency_metrics(latency_metrics, new_latency_ms, chunk_count) do
    # Set first chunk latency if this is the first chunk
    first_chunk_latency = latency_metrics.first_chunk_latency_ms || new_latency_ms

    # Update running average
    current_avg = latency_metrics.average_chunk_latency_ms
    new_avg = (current_avg * (chunk_count - 1) + new_latency_ms) / chunk_count

    # Update min/max
    new_max = max(latency_metrics.max_chunk_latency_ms, new_latency_ms)
    new_min = min(latency_metrics.min_chunk_latency_ms, new_latency_ms)

    %{latency_metrics |
      first_chunk_latency_ms: first_chunk_latency,
      average_chunk_latency_ms: new_avg,
      max_chunk_latency_ms: new_max,
      min_chunk_latency_ms: new_min
    }
  end

  # Calculate final session metrics
  defp calculate_final_session_metrics(session_metrics) do
    # Calculate P95 latency from stored latency data
    latencies = :ets.lookup(:chunk_latencies, session_metrics.session_id)
    |> Enum.map(fn {_, {_, latency_ms, _, _}} -> latency_ms end)
    |> Enum.sort()

    p95_latency = if length(latencies) > 0 do
      p95_index = trunc(length(latencies) * 0.95)
      Enum.at(latencies, p95_index, 0.0)
    else
      0.0
    end

    # Update latency metrics with P95
    updated_latency = %{session_metrics.latency_metrics | p95_chunk_latency_ms: p95_latency}

    # Calculate final success rate
    total_operations = session_metrics.chunks_received + session_metrics.quality_metrics.error_count
    success_rate = if total_operations > 0 do
      session_metrics.chunks_received / total_operations
    else
      1.0
    end

    updated_quality = %{session_metrics.quality_metrics | success_rate: success_rate}

    %{session_metrics |
      latency_metrics: updated_latency,
      quality_metrics: updated_quality
    }
  end

  # Calculate aggregated metrics across all sessions
  defp calculate_aggregated_metrics(time_window_hours) do
    cutoff_time = System.system_time(:second) - (time_window_hours * 3600)

    sessions = :ets.tab2list(:session_metrics)
    |> Enum.map(fn {_, metrics} -> metrics end)
    |> Enum.filter(fn metrics ->
      start_time_seconds = metrics.start_time / 1_000_000
      start_time_seconds >= cutoff_time
    end)

    if length(sessions) > 0 do
      %{
        total_sessions: length(sessions),
        active_sessions: Enum.count(sessions, &(&1.status == :active)),
        completed_sessions: Enum.count(sessions, &(&1.status == :completed)),
        error_sessions: Enum.count(sessions, &(&1.status == :error)),
        average_latency_ms: Enum.map(sessions, & &1.latency_metrics.average_chunk_latency_ms) |> average(),
        average_throughput_bps: Enum.map(sessions, & &1.throughput_metrics.effective_throughput_bps) |> average(),
        total_chunks: Enum.sum(Enum.map(sessions, & &1.chunks_received)),
        total_bytes: Enum.sum(Enum.map(sessions, & &1.bytes_received)),
        overall_success_rate: Enum.map(sessions, & &1.quality_metrics.success_rate) |> average(),
        total_errors: Enum.sum(Enum.map(sessions, & &1.quality_metrics.error_count)),
        total_reconnections: Enum.sum(Enum.map(sessions, & &1.quality_metrics.reconnection_count))
      }
    else
      %{
        total_sessions: 0,
        active_sessions: 0,
        completed_sessions: 0,
        error_sessions: 0,
        average_latency_ms: 0.0,
        average_throughput_bps: 0.0,
        total_chunks: 0,
        total_bytes: 0,
        overall_success_rate: 1.0,
        total_errors: 0,
        total_reconnections: 0
      }
    end
  end

  # Calculate provider comparison metrics
  defp calculate_provider_comparison(time_window_hours) do
    cutoff_time = System.system_time(:second) - (time_window_hours * 3600)

    sessions = :ets.tab2list(:session_metrics)
    |> Enum.map(fn {_, metrics} -> metrics end)
    |> Enum.filter(fn metrics ->
      start_time_seconds = metrics.start_time / 1_000_000
      start_time_seconds >= cutoff_time
    end)
    |> Enum.group_by(& &1.provider)

    Enum.map(sessions, fn {provider, provider_sessions} ->
      {provider, %{
        session_count: length(provider_sessions),
        average_latency_ms: Enum.map(provider_sessions, & &1.latency_metrics.average_chunk_latency_ms) |> average(),
        average_throughput_bps: Enum.map(provider_sessions, & &1.throughput_metrics.effective_throughput_bps) |> average(),
        success_rate: Enum.map(provider_sessions, & &1.quality_metrics.success_rate) |> average(),
        error_rate: calculate_error_rate(provider_sessions),
        reconnection_rate: calculate_reconnection_rate(provider_sessions)
      }}
    end)
    |> Enum.into(%{})
  end

  # Check for performance alerts on session completion
  defp check_session_alerts(session_metrics, thresholds) do
    # Check various alert conditions
    if session_metrics.latency_metrics.average_chunk_latency_ms > thresholds.high_latency_ms do
      create_alert(:session_high_latency, session_metrics.session_id, %{
        average_latency_ms: session_metrics.latency_metrics.average_chunk_latency_ms,
        threshold_ms: thresholds.high_latency_ms
      })
    end

    if session_metrics.throughput_metrics.effective_throughput_bps < thresholds.low_throughput_bps do
      create_alert(:session_low_throughput, session_metrics.session_id, %{
        throughput_bps: session_metrics.throughput_metrics.effective_throughput_bps,
        threshold_bps: thresholds.low_throughput_bps
      })
    end

    if session_metrics.quality_metrics.success_rate < (1.0 - thresholds.high_error_rate) do
      create_alert(:session_high_error_rate, session_metrics.session_id, %{
        success_rate: session_metrics.quality_metrics.success_rate,
        error_rate: 1.0 - session_metrics.quality_metrics.success_rate
      })
    end
  end

  # Create a performance alert
  defp create_alert(alert_type, session_id, details) do
    alert_id = "#{alert_type}_#{session_id}_#{System.system_time(:second)}"

    alert = %{
      id: alert_id,
      type: alert_type,
      session_id: session_id,
      timestamp: System.system_time(:second),
      details: details,
      severity: determine_alert_severity(alert_type, details)
    }

    :ets.insert(:performance_alerts, {alert_id, alert})

    Logger.warning("Performance alert created: #{alert_type} for session #{session_id}")
  end

  # Determine alert severity
  defp determine_alert_severity(alert_type, details) do
    case alert_type do
      :high_latency ->
        latency = Map.get(details, :latency_ms, 0)
        cond do
          latency > 10000 -> :critical
          latency > 5000 -> :high
          true -> :medium
        end

      :high_error_rate ->
        error_rate = Map.get(details, :error_rate, 0)
        cond do
          error_rate > 0.5 -> :critical
          error_rate > 0.2 -> :high
          true -> :medium
        end

      _ ->
        :medium
    end
  end

  # Helper functions
  defp average([]), do: 0.0
  defp average(list), do: Enum.sum(list) / length(list)

  defp calculate_error_rate(sessions) do
    total_operations = Enum.sum(Enum.map(sessions, fn s -> s.chunks_received + s.quality_metrics.error_count end))
    total_errors = Enum.sum(Enum.map(sessions, & &1.quality_metrics.error_count))

    if total_operations > 0, do: total_errors / total_operations, else: 0.0
  end

  defp calculate_reconnection_rate(sessions) do
    total_sessions = length(sessions)
    sessions_with_reconnections = Enum.count(sessions, &(&1.quality_metrics.reconnection_count > 0))

    if total_sessions > 0, do: sessions_with_reconnections / total_sessions, else: 0.0
  end

  # Periodic cleanup of old metrics
  defp perform_cleanup do
    cutoff_time = System.system_time(:second) - (@metrics_retention_hours * 3600)

    # Clean up old session metrics
    :ets.tab2list(:session_metrics)
    |> Enum.each(fn {session_id, metrics} ->
      start_time_seconds = metrics.start_time / 1_000_000
      if start_time_seconds < cutoff_time do
        :ets.delete(:session_metrics, session_id)
      end
    end)

    # Clean up old latency data
    :ets.tab2list(:chunk_latencies)
    |> Enum.each(fn {session_id, {timestamp, _, _, _}} ->
      if timestamp < cutoff_time do
        :ets.delete_object(:chunk_latencies, {session_id, {timestamp, nil, nil, nil}})
      end
    end)

    # Clean up old alerts
    :ets.tab2list(:performance_alerts)
    |> Enum.each(fn {alert_id, alert} ->
      if alert.timestamp < cutoff_time do
        :ets.delete(:performance_alerts, alert_id)
      end
    end)

    Logger.debug("Performance metrics cleanup completed")
  end

  # Periodic performance analysis
  defp perform_analysis(thresholds) do
    # Analyze recent performance trends
    recent_metrics = calculate_aggregated_metrics(1)  # Last hour

    # Check for system-wide alerts
    if recent_metrics.average_latency_ms > thresholds.high_latency_ms do
      create_alert(:system_high_latency, "system", %{
        average_latency_ms: recent_metrics.average_latency_ms,
        threshold_ms: thresholds.high_latency_ms
      })
    end

    if recent_metrics.average_throughput_bps < thresholds.low_throughput_bps do
      create_alert(:system_low_throughput, "system", %{
        throughput_bps: recent_metrics.average_throughput_bps,
        threshold_bps: thresholds.low_throughput_bps
      })
    end

    error_rate = if recent_metrics.total_sessions > 0 do
      recent_metrics.error_sessions / recent_metrics.total_sessions
    else
      0.0
    end

    if error_rate > thresholds.high_error_rate do
      create_alert(:system_high_error_rate, "system", %{
        error_rate: error_rate,
        threshold: thresholds.high_error_rate
      })
    end

    Logger.debug("Performance analysis completed")
  end

  # Schedule periodic cleanup
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_metrics, 3600_000)  # 1 hour
  end

  # Schedule periodic analysis
  defp schedule_analysis do
    Process.send_after(self(), :analyze_performance, 300_000)  # 5 minutes
  end
end
