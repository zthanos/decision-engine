# lib/decision_engine/streaming_performance_monitor.ex
defmodule DecisionEngine.StreamingPerformanceMonitor do
  @moduledoc """
  Comprehensive performance monitoring for streaming operations.

  This module provides real-time monitoring and metrics collection for:
  - Chunk processing latency tracking
  - Throughput monitoring for concurrent sessions
  - Provider-specific performance analysis
  - Resource usage monitoring
  - Performance alerting and reporting
  """

  use GenServer
  require Logger

  @typedoc """
  Performance metrics structure for streaming operations.
  """
  @type performance_metrics :: %{
    # Latency metrics
    avg_chunk_latency_ms: float(),
    p95_chunk_latency_ms: float(),
    p99_chunk_latency_ms: float(),
    max_chunk_latency_ms: float(),

    # Throughput metrics
    chunks_per_second: float(),
    bytes_per_second: float(),
    concurrent_sessions: integer(),

    # Provider metrics
    provider_performance: map(),

    # Resource metrics
    memory_usage_mb: float(),
    cpu_usage_percent: float(),

    # Error metrics
    error_rate_percent: float(),
    timeout_rate_percent: float(),

    # Timing
    measurement_window_ms: integer(),
    last_updated: DateTime.t()
  }

  @typedoc """
  Latency measurement for individual chunks.
  """
  @type latency_measurement :: %{
    session_id: String.t(),
    provider: atom(),
    chunk_size: integer(),
    processing_time_us: integer(),
    timestamp: integer()
  }

  # Performance monitoring configuration
  @measurement_window_ms 60_000  # 1 minute rolling window
  @max_measurements 10_000       # Maximum measurements to keep in memory
  @alert_threshold_ms 100        # Alert if chunk processing exceeds 100ms
  @performance_report_interval 30_000  # Report every 30 seconds

  ## Public API

  @doc """
  Starts the streaming performance monitor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a chunk processing latency measurement.

  ## Parameters
  - session_id: The streaming session identifier
  - provider: The LLM provider used
  - chunk_size: Size of the processed chunk in bytes
  - processing_time_us: Processing time in microseconds
  """
  @spec record_chunk_latency(String.t(), atom(), integer(), integer()) :: :ok
  def record_chunk_latency(session_id, provider, chunk_size, processing_time_us) do
    measurement = %{
      session_id: session_id,
      provider: provider,
      chunk_size: chunk_size,
      processing_time_us: processing_time_us,
      timestamp: System.monotonic_time(:microsecond)
    }

    GenServer.cast(__MODULE__, {:record_latency, measurement})
  end

  @doc """
  Records session start for concurrent session tracking.

  ## Parameters
  - session_id: The streaming session identifier
  - provider: The LLM provider used
  """
  @spec record_session_start(String.t(), atom()) :: :ok
  def record_session_start(session_id, provider) do
    GenServer.cast(__MODULE__, {:session_start, session_id, provider})
  end

  @doc """
  Records session end for concurrent session tracking.

  ## Parameters
  - session_id: The streaming session identifier
  """
  @spec record_session_end(String.t()) :: :ok
  def record_session_end(session_id) do
    GenServer.cast(__MODULE__, {:session_end, session_id})
  end

  @doc """
  Records an error for error rate tracking.

  ## Parameters
  - session_id: The streaming session identifier
  - error_type: Type of error (:timeout, :network, :parsing, etc.)
  - provider: The LLM provider where error occurred
  """
  @spec record_error(String.t(), atom(), atom()) :: :ok
  def record_error(session_id, error_type, provider) do
    GenServer.cast(__MODULE__, {:record_error, session_id, error_type, provider})
  end

  @doc """
  Gets current performance metrics.

  ## Returns
  - Current performance metrics structure
  """
  @spec get_current_metrics() :: performance_metrics()
  def get_current_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Gets performance metrics for a specific provider.

  ## Parameters
  - provider: The LLM provider to get metrics for

  ## Returns
  - Provider-specific performance metrics
  """
  @spec get_provider_metrics(atom()) :: map()
  def get_provider_metrics(provider) do
    GenServer.call(__MODULE__, {:get_provider_metrics, provider})
  end

  @doc """
  Gets performance history for the specified time window.

  ## Parameters
  - window_ms: Time window in milliseconds (default: 5 minutes)

  ## Returns
  - List of historical performance snapshots
  """
  @spec get_performance_history(integer()) :: [performance_metrics()]
  def get_performance_history(window_ms \\ 300_000) do
    GenServer.call(__MODULE__, {:get_history, window_ms})
  end

  @doc """
  Checks if current performance meets SLA requirements.

  ## Returns
  - {:ok, :within_sla} if performance is acceptable
  - {:warning, issues} if performance is degraded
  - {:critical, issues} if performance is severely impacted
  """
  @spec check_sla_compliance() :: {:ok, :within_sla} | {:warning, [String.t()]} | {:critical, [String.t()]}
  def check_sla_compliance do
    GenServer.call(__MODULE__, :check_sla)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic performance reporting
    Process.send_after(self(), :performance_report, @performance_report_interval)

    state = %{
      # Latency measurements (circular buffer)
      latency_measurements: :queue.new(),
      measurement_count: 0,

      # Active sessions tracking
      active_sessions: %{},

      # Error tracking
      error_measurements: :queue.new(),
      error_count: 0,

      # Performance history
      performance_history: :queue.new(),

      # Resource monitoring
      last_memory_check: 0,
      last_cpu_check: 0,

      # Alerting state
      last_alert_time: 0,
      alert_cooldown_ms: 60_000  # 1 minute cooldown between alerts
    }

    Logger.info("Streaming performance monitor started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:record_latency, measurement}, state) do
    # Add measurement to circular buffer
    {updated_queue, updated_count} = add_to_circular_buffer(
      state.latency_measurements,
      state.measurement_count,
      measurement,
      @max_measurements
    )

    # Check for performance alerts
    check_latency_alert(measurement)

    {:noreply, %{state |
      latency_measurements: updated_queue,
      measurement_count: updated_count
    }}
  end

  @impl true
  def handle_cast({:session_start, session_id, provider}, state) do
    session_info = %{
      provider: provider,
      start_time: System.monotonic_time(:microsecond),
      chunk_count: 0,
      total_bytes: 0
    }

    updated_sessions = Map.put(state.active_sessions, session_id, session_info)

    {:noreply, %{state | active_sessions: updated_sessions}}
  end

  @impl true
  def handle_cast({:session_end, session_id}, state) do
    updated_sessions = Map.delete(state.active_sessions, session_id)

    {:noreply, %{state | active_sessions: updated_sessions}}
  end

  @impl true
  def handle_cast({:record_error, session_id, error_type, provider}, state) do
    error_measurement = %{
      session_id: session_id,
      error_type: error_type,
      provider: provider,
      timestamp: System.monotonic_time(:microsecond)
    }

    # Add error to circular buffer
    {updated_queue, updated_count} = add_to_circular_buffer(
      state.error_measurements,
      state.error_count,
      error_measurement,
      @max_measurements
    )

    {:noreply, %{state |
      error_measurements: updated_queue,
      error_count: updated_count
    }}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = calculate_current_metrics(state)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:get_provider_metrics, provider}, _from, state) do
    metrics = calculate_provider_metrics(state, provider)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:get_history, window_ms}, _from, state) do
    cutoff_time = System.monotonic_time(:microsecond) - (window_ms * 1000)

    history = :queue.to_list(state.performance_history)
    |> Enum.filter(fn metrics ->
      DateTime.to_unix(metrics.last_updated, :microsecond) >= cutoff_time
    end)

    {:reply, history, state}
  end

  @impl true
  def handle_call(:check_sla, _from, state) do
    sla_result = check_sla_compliance_internal(state)
    {:reply, sla_result, state}
  end

  @impl true
  def handle_info(:performance_report, state) do
    # Calculate and store current metrics
    current_metrics = calculate_current_metrics(state)

    # Add to performance history
    updated_history = add_to_circular_buffer(
      state.performance_history,
      :queue.len(state.performance_history),
      current_metrics,
      100  # Keep last 100 performance snapshots
    ) |> elem(0)

    # Log performance summary
    log_performance_summary(current_metrics)

    # Schedule next report
    Process.send_after(self(), :performance_report, @performance_report_interval)

    {:noreply, %{state | performance_history: updated_history}}
  end

  ## Private Functions

  # Add item to circular buffer with maximum size
  defp add_to_circular_buffer(queue, count, item, max_size) do
    if count >= max_size do
      # Remove oldest item and add new one
      {_oldest, trimmed_queue} = :queue.out(queue)
      updated_queue = :queue.in(item, trimmed_queue)
      {updated_queue, count}
    else
      # Just add the new item
      updated_queue = :queue.in(item, queue)
      {updated_queue, count + 1}
    end
  end

  # Calculate current performance metrics
  defp calculate_current_metrics(state) do
    current_time = System.monotonic_time(:microsecond)
    window_start = current_time - (@measurement_window_ms * 1000)

    # Filter measurements within the window
    recent_measurements = :queue.to_list(state.latency_measurements)
    |> Enum.filter(&(&1.timestamp >= window_start))

    # Calculate latency statistics
    latency_stats = calculate_latency_statistics(recent_measurements)

    # Calculate throughput metrics
    throughput_stats = calculate_throughput_statistics(recent_measurements, @measurement_window_ms)

    # Calculate provider-specific metrics
    provider_metrics = calculate_all_provider_metrics(recent_measurements)

    # Calculate error rates
    recent_errors = :queue.to_list(state.error_measurements)
    |> Enum.filter(&(&1.timestamp >= window_start))

    error_stats = calculate_error_statistics(recent_errors, recent_measurements)

    # Get resource usage
    resource_stats = get_resource_usage()

    %{
      avg_chunk_latency_ms: latency_stats.avg_ms,
      p95_chunk_latency_ms: latency_stats.p95_ms,
      p99_chunk_latency_ms: latency_stats.p99_ms,
      max_chunk_latency_ms: latency_stats.max_ms,
      chunks_per_second: throughput_stats.chunks_per_second,
      bytes_per_second: throughput_stats.bytes_per_second,
      concurrent_sessions: map_size(state.active_sessions),
      provider_performance: provider_metrics,
      memory_usage_mb: resource_stats.memory_mb,
      cpu_usage_percent: resource_stats.cpu_percent,
      error_rate_percent: error_stats.error_rate_percent,
      timeout_rate_percent: error_stats.timeout_rate_percent,
      measurement_window_ms: @measurement_window_ms,
      last_updated: DateTime.utc_now()
    }
  end

  # Calculate latency statistics from measurements
  defp calculate_latency_statistics([]), do: %{avg_ms: 0.0, p95_ms: 0.0, p99_ms: 0.0, max_ms: 0.0}
  defp calculate_latency_statistics(measurements) do
    latencies_ms = Enum.map(measurements, fn measurement -> measurement.processing_time_us / 1000 end)
    sorted_latencies = Enum.sort(latencies_ms)

    count = length(sorted_latencies)
    avg_ms = Enum.sum(sorted_latencies) / count
    max_ms = Enum.max(sorted_latencies)

    p95_index = trunc(count * 0.95)
    p99_index = trunc(count * 0.99)

    p95_ms = if p95_index > 0, do: Enum.at(sorted_latencies, p95_index - 1), else: 0.0
    p99_ms = if p99_index > 0, do: Enum.at(sorted_latencies, p99_index - 1), else: 0.0

    %{
      avg_ms: Float.round(avg_ms, 2),
      p95_ms: Float.round(p95_ms, 2),
      p99_ms: Float.round(p99_ms, 2),
      max_ms: Float.round(max_ms, 2)
    }
  end

  # Calculate throughput statistics
  defp calculate_throughput_statistics([], _window_ms), do: %{chunks_per_second: 0.0, bytes_per_second: 0.0}
  defp calculate_throughput_statistics(measurements, window_ms) do
    total_chunks = length(measurements)
    total_bytes = Enum.sum(Enum.map(measurements, &(&1.chunk_size)))

    window_seconds = window_ms / 1000

    %{
      chunks_per_second: Float.round(total_chunks / window_seconds, 2),
      bytes_per_second: Float.round(total_bytes / window_seconds, 2)
    }
  end

  # Calculate provider-specific metrics
  defp calculate_provider_metrics(state, provider) do
    current_time = System.monotonic_time(:microsecond)
    window_start = current_time - (@measurement_window_ms * 1000)

    provider_measurements = :queue.to_list(state.latency_measurements)
    |> Enum.filter(&(&1.provider == provider and &1.timestamp >= window_start))

    if Enum.empty?(provider_measurements) do
      %{
        provider: provider,
        avg_latency_ms: 0.0,
        chunk_count: 0,
        error_count: 0,
        active_sessions: 0
      }
    else
      latency_stats = calculate_latency_statistics(provider_measurements)

      provider_errors = :queue.to_list(state.error_measurements)
      |> Enum.filter(&(&1.provider == provider and &1.timestamp >= window_start))

      active_sessions = state.active_sessions
      |> Enum.count(fn {_id, session} -> session.provider == provider end)

      %{
        provider: provider,
        avg_latency_ms: latency_stats.avg_ms,
        p95_latency_ms: latency_stats.p95_ms,
        chunk_count: length(provider_measurements),
        error_count: length(provider_errors),
        active_sessions: active_sessions
      }
    end
  end

  # Calculate metrics for all providers
  defp calculate_all_provider_metrics(measurements) do
    measurements
    |> Enum.group_by(&(&1.provider))
    |> Enum.map(fn {provider, provider_measurements} ->
      latency_stats = calculate_latency_statistics(provider_measurements)

      {provider, %{
        avg_latency_ms: latency_stats.avg_ms,
        p95_latency_ms: latency_stats.p95_ms,
        chunk_count: length(provider_measurements)
      }}
    end)
    |> Map.new()
  end

  # Calculate error statistics
  defp calculate_error_statistics(errors, measurements) do
    total_operations = length(measurements) + length(errors)

    if total_operations == 0 do
      %{error_rate_percent: 0.0, timeout_rate_percent: 0.0}
    else
      error_count = length(errors)
      timeout_count = Enum.count(errors, &(&1.error_type == :timeout))

      %{
        error_rate_percent: Float.round((error_count / total_operations) * 100, 2),
        timeout_rate_percent: Float.round((timeout_count / total_operations) * 100, 2)
      }
    end
  end

  # Get current resource usage
  defp get_resource_usage do
    # Get memory usage
    memory_mb = case :erlang.memory(:total) do
      memory_bytes when is_integer(memory_bytes) -> memory_bytes / (1024 * 1024)
      _ -> 0.0
    end

    # CPU usage is harder to get in real-time, so we'll use a placeholder
    # In production, this could integrate with system monitoring tools
    cpu_percent = 0.0

    %{
      memory_mb: Float.round(memory_mb, 2),
      cpu_percent: cpu_percent
    }
  end

  # Check for latency alerts
  defp check_latency_alert(measurement) do
    latency_ms = measurement.processing_time_us / 1000

    if latency_ms > @alert_threshold_ms do
      Logger.warning("High chunk processing latency detected: #{Float.round(latency_ms, 2)}ms for session #{measurement.session_id} (provider: #{measurement.provider})")
    end
  end

  # Check SLA compliance
  defp check_sla_compliance_internal(state) do
    metrics = calculate_current_metrics(state)

    issues = []

    # Check latency SLA (95th percentile should be under 100ms)
    issues = if metrics.p95_chunk_latency_ms > 100 do
      ["P95 latency (#{metrics.p95_chunk_latency_ms}ms) exceeds 100ms SLA" | issues]
    else
      issues
    end

    # Check error rate SLA (should be under 5%)
    issues = if metrics.error_rate_percent > 5.0 do
      ["Error rate (#{metrics.error_rate_percent}%) exceeds 5% SLA" | issues]
    else
      issues
    end

    # Check timeout rate SLA (should be under 1%)
    issues = if metrics.timeout_rate_percent > 1.0 do
      ["Timeout rate (#{metrics.timeout_rate_percent}%) exceeds 1% SLA" | issues]
    else
      issues
    end

    # Determine severity
    cond do
      Enum.empty?(issues) -> {:ok, :within_sla}
      metrics.p95_chunk_latency_ms > 200 or metrics.error_rate_percent > 10 -> {:critical, issues}
      true -> {:warning, issues}
    end
  end

  # Log performance summary
  defp log_performance_summary(metrics) do
    Logger.info("Streaming Performance Summary: " <>
      "P95 latency: #{metrics.p95_chunk_latency_ms}ms, " <>
      "Throughput: #{metrics.chunks_per_second} chunks/s, " <>
      "Active sessions: #{metrics.concurrent_sessions}, " <>
      "Error rate: #{metrics.error_rate_percent}%")
  end
end
