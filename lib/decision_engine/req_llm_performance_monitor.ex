# lib/decision_engine/req_llm_performance_monitor.ex
defmodule DecisionEngine.ReqLLMPerformanceMonitor do
  @moduledoc """
  Monitors performance metrics for ReqLLM migration validation.

  Tracks key performance indicators to determine migration success
  and trigger automatic rollback if performance degrades.
  """

  use GenServer
  require Logger

  @metrics_window_minutes 60
  @max_stored_metrics 1440  # 24 hours of minute-by-minute data

  # Client API

  @doc """
  Starts the performance monitor.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a request completion event.
  """
  @spec record_request(atom(), atom(), integer(), boolean()) :: :ok
  def record_request(provider, operation_type, duration_ms, success) do
    GenServer.cast(__MODULE__, {:record_request, provider, operation_type, duration_ms, success})
  end

  @doc """
  Records a streaming event.
  """
  @spec record_streaming_event(atom(), boolean(), integer()) :: :ok
  def record_streaming_event(provider, success, duration_ms) do
    GenServer.cast(__MODULE__, {:record_streaming_event, provider, success, duration_ms})
  end

  @doc """
  Records connection pool metrics.
  """
  @spec record_connection_pool_metrics(atom(), map()) :: :ok
  def record_connection_pool_metrics(provider, metrics) do
    GenServer.cast(__MODULE__, {:record_connection_pool_metrics, provider, metrics})
  end

  @doc """
  Gets current performance metrics.
  """
  @spec get_current_metrics() :: {:ok, map()} | {:error, term()}
  def get_current_metrics() do
    GenServer.call(__MODULE__, :get_current_metrics)
  end

  @doc """
  Gets performance comparison between ReqLLM and legacy implementation.
  """
  @spec get_performance_comparison() :: {:ok, map()} | {:error, term()}
  def get_performance_comparison() do
    GenServer.call(__MODULE__, :get_performance_comparison)
  end

  @doc """
  Gets detailed metrics for a specific time window.
  """
  @spec get_metrics_window(integer()) :: {:ok, map()} | {:error, term()}
  def get_metrics_window(minutes_back) do
    GenServer.call(__MODULE__, {:get_metrics_window, minutes_back})
  end

  @doc """
  Resets all metrics (for testing).
  """
  @spec reset_metrics() :: :ok
  def reset_metrics() do
    GenServer.call(__MODULE__, :reset_metrics)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting ReqLLM Performance Monitor")

    state = %{
      reqllm_metrics: %{
        requests: [],
        streaming_events: [],
        connection_pool_metrics: [],
        error_counts: %{},
        latency_samples: []
      },
      legacy_metrics: %{
        requests: [],
        streaming_events: [],
        error_counts: %{},
        latency_samples: []
      },
      last_cleanup: System.system_time(:second)
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_request, provider, operation_type, duration_ms, success}, state) do
    timestamp = System.system_time(:second)

    request_event = %{
      provider: provider,
      operation_type: operation_type,
      duration_ms: duration_ms,
      success: success,
      timestamp: timestamp
    }

    # Determine if this is ReqLLM or legacy based on provider context
    implementation = determine_implementation(provider, operation_type)

    new_state = case implementation do
      :reqllm ->
        update_reqllm_metrics(state, request_event)
      :legacy ->
        update_legacy_metrics(state, request_event)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_streaming_event, provider, success, duration_ms}, state) do
    timestamp = System.system_time(:second)

    streaming_event = %{
      provider: provider,
      success: success,
      duration_ms: duration_ms,
      timestamp: timestamp
    }

    # Determine implementation type
    implementation = determine_implementation(provider, :streaming)

    new_state = case implementation do
      :reqllm ->
        reqllm_metrics = state.reqllm_metrics
        updated_events = [streaming_event | reqllm_metrics.streaming_events]
        updated_reqllm = %{reqllm_metrics | streaming_events: updated_events}
        %{state | reqllm_metrics: updated_reqllm}

      :legacy ->
        legacy_metrics = state.legacy_metrics
        updated_events = [streaming_event | legacy_metrics.streaming_events]
        updated_legacy = %{legacy_metrics | streaming_events: updated_events}
        %{state | legacy_metrics: updated_legacy}
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_connection_pool_metrics, provider, metrics}, state) do
    timestamp = System.system_time(:second)

    pool_metrics = Map.put(metrics, :timestamp, timestamp)

    reqllm_metrics = state.reqllm_metrics
    updated_pool_metrics = [pool_metrics | reqllm_metrics.connection_pool_metrics]
    updated_reqllm = %{reqllm_metrics | connection_pool_metrics: updated_pool_metrics}

    new_state = %{state | reqllm_metrics: updated_reqllm}
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_current_metrics, _from, state) do
    current_time = System.system_time(:second)
    window_start = current_time - (@metrics_window_minutes * 60)

    reqllm_metrics = calculate_window_metrics(state.reqllm_metrics, window_start, current_time)
    legacy_metrics = calculate_window_metrics(state.legacy_metrics, window_start, current_time)

    metrics = %{
      reqllm: reqllm_metrics,
      legacy: legacy_metrics,
      comparison: calculate_comparison_metrics(reqllm_metrics, legacy_metrics),
      window_minutes: @metrics_window_minutes,
      timestamp: current_time
    }

    # Extract key metrics for migration criteria
    key_metrics = %{
      error_rate: Map.get(reqllm_metrics, :error_rate, 0.0),
      latency_ratio: calculate_latency_ratio(reqllm_metrics, legacy_metrics),
      streaming_success_rate: Map.get(reqllm_metrics, :streaming_success_rate, 1.0),
      total_requests: Map.get(reqllm_metrics, :total_requests, 0),
      connection_pool_efficiency: Map.get(reqllm_metrics, :connection_pool_efficiency, 0.0),
      performance_improvement: calculate_performance_improvement(reqllm_metrics, legacy_metrics)
    }

    result = Map.merge(metrics, key_metrics)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:get_performance_comparison, _from, state) do
    current_time = System.system_time(:second)
    window_start = current_time - (@metrics_window_minutes * 60)

    reqllm_metrics = calculate_window_metrics(state.reqllm_metrics, window_start, current_time)
    legacy_metrics = calculate_window_metrics(state.legacy_metrics, window_start, current_time)

    comparison = calculate_detailed_comparison(reqllm_metrics, legacy_metrics)

    {:reply, {:ok, comparison}, state}
  end

  @impl true
  def handle_call({:get_metrics_window, minutes_back}, _from, state) do
    current_time = System.system_time(:second)
    window_start = current_time - (minutes_back * 60)

    reqllm_metrics = calculate_window_metrics(state.reqllm_metrics, window_start, current_time)
    legacy_metrics = calculate_window_metrics(state.legacy_metrics, window_start, current_time)

    result = %{
      reqllm: reqllm_metrics,
      legacy: legacy_metrics,
      window_minutes: minutes_back,
      timestamp: current_time
    }

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:reset_metrics, _from, _state) do
    Logger.info("Resetting all performance metrics")

    new_state = %{
      reqllm_metrics: %{
        requests: [],
        streaming_events: [],
        connection_pool_metrics: [],
        error_counts: %{},
        latency_samples: []
      },
      legacy_metrics: %{
        requests: [],
        streaming_events: [],
        error_counts: %{},
        latency_samples: []
      },
      last_cleanup: System.system_time(:second)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:cleanup_old_metrics, state) do
    new_state = cleanup_old_metrics(state)
    schedule_cleanup()
    {:noreply, new_state}
  end

  # Private Functions

  defp determine_implementation(provider, operation_type) do
    # Check if ReqLLM is enabled for this context
    context = %{provider: provider, operation_type: operation_type}

    case DecisionEngine.ReqLLMFeatureFlags.enabled?(context) do
      true -> :reqllm
      false -> :legacy
    end
  end

  defp update_reqllm_metrics(state, request_event) do
    reqllm_metrics = state.reqllm_metrics

    # Add to requests list
    updated_requests = [request_event | reqllm_metrics.requests]

    # Update error counts
    error_key = if request_event.success, do: :success, else: :error
    updated_error_counts = Map.update(reqllm_metrics.error_counts, error_key, 1, &(&1 + 1))

    # Add latency sample
    updated_latency_samples = [request_event.duration_ms | reqllm_metrics.latency_samples]

    updated_reqllm = %{reqllm_metrics |
      requests: updated_requests,
      error_counts: updated_error_counts,
      latency_samples: updated_latency_samples
    }

    %{state | reqllm_metrics: updated_reqllm}
  end

  defp update_legacy_metrics(state, request_event) do
    legacy_metrics = state.legacy_metrics

    # Add to requests list
    updated_requests = [request_event | legacy_metrics.requests]

    # Update error counts
    error_key = if request_event.success, do: :success, else: :error
    updated_error_counts = Map.update(legacy_metrics.error_counts, error_key, 1, &(&1 + 1))

    # Add latency sample
    updated_latency_samples = [request_event.duration_ms | legacy_metrics.latency_samples]

    updated_legacy = %{legacy_metrics |
      requests: updated_requests,
      error_counts: updated_error_counts,
      latency_samples: updated_latency_samples
    }

    %{state | legacy_metrics: updated_legacy}
  end

  defp calculate_window_metrics(metrics, window_start, window_end) do
    # Filter requests within time window
    window_requests = Enum.filter(metrics.requests, fn req ->
      req.timestamp >= window_start and req.timestamp <= window_end
    end)

    # Filter streaming events within time window
    window_streaming = Enum.filter(metrics.streaming_events, fn event ->
      event.timestamp >= window_start and event.timestamp <= window_end
    end)

    # Filter connection pool metrics within time window
    window_pool_metrics = Enum.filter(Map.get(metrics, :connection_pool_metrics, []), fn pool ->
      pool.timestamp >= window_start and pool.timestamp <= window_end
    end)

    total_requests = length(window_requests)
    successful_requests = Enum.count(window_requests, & &1.success)
    failed_requests = total_requests - successful_requests

    error_rate = if total_requests > 0, do: failed_requests / total_requests, else: 0.0

    # Calculate latency statistics
    latencies = Enum.map(window_requests, & &1.duration_ms)
    latency_stats = calculate_latency_stats(latencies)

    # Calculate streaming statistics
    total_streaming = length(window_streaming)
    successful_streaming = Enum.count(window_streaming, & &1.success)
    streaming_success_rate = if total_streaming > 0, do: successful_streaming / total_streaming, else: 1.0

    # Calculate connection pool efficiency
    pool_efficiency = calculate_pool_efficiency(window_pool_metrics)

    %{
      total_requests: total_requests,
      successful_requests: successful_requests,
      failed_requests: failed_requests,
      error_rate: error_rate,
      latency_stats: latency_stats,
      streaming_success_rate: streaming_success_rate,
      total_streaming_events: total_streaming,
      connection_pool_efficiency: pool_efficiency,
      window_start: window_start,
      window_end: window_end
    }
  end

  defp calculate_latency_stats([]), do: %{avg: 0, median: 0, p95: 0, p99: 0}
  defp calculate_latency_stats(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    avg = Enum.sum(sorted) / count
    median = Enum.at(sorted, div(count, 2))
    p95 = Enum.at(sorted, trunc(count * 0.95))
    p99 = Enum.at(sorted, trunc(count * 0.99))

    %{avg: avg, median: median, p95: p95, p99: p99}
  end

  defp calculate_pool_efficiency([]), do: 0.0
  defp calculate_pool_efficiency(pool_metrics) do
    if Enum.empty?(pool_metrics) do
      0.0
    else
      # Calculate average connection reuse rate
      reuse_rates = Enum.map(pool_metrics, fn metrics ->
        total_connections = Map.get(metrics, :total_connections, 1)
        reused_connections = Map.get(metrics, :reused_connections, 0)
        reused_connections / total_connections
      end)

      Enum.sum(reuse_rates) / length(reuse_rates)
    end
  end

  defp calculate_comparison_metrics(reqllm_metrics, legacy_metrics) do
    %{
      latency_improvement: calculate_latency_improvement(reqllm_metrics, legacy_metrics),
      error_rate_improvement: calculate_error_rate_improvement(reqllm_metrics, legacy_metrics),
      throughput_improvement: calculate_throughput_improvement(reqllm_metrics, legacy_metrics)
    }
  end

  defp calculate_latency_ratio(reqllm_metrics, legacy_metrics) do
    reqllm_avg = get_in(reqllm_metrics, [:latency_stats, :avg]) || 1000
    legacy_avg = get_in(legacy_metrics, [:latency_stats, :avg]) || 1000

    if legacy_avg > 0, do: reqllm_avg / legacy_avg, else: 1.0
  end

  defp calculate_performance_improvement(reqllm_metrics, legacy_metrics) do
    # Calculate overall performance improvement as inverse of latency ratio
    latency_ratio = calculate_latency_ratio(reqllm_metrics, legacy_metrics)

    if latency_ratio > 0, do: 1.0 / latency_ratio, else: 1.0
  end

  defp calculate_latency_improvement(reqllm_metrics, legacy_metrics) do
    reqllm_avg = get_in(reqllm_metrics, [:latency_stats, :avg]) || 0
    legacy_avg = get_in(legacy_metrics, [:latency_stats, :avg]) || 0

    if legacy_avg > 0 do
      (legacy_avg - reqllm_avg) / legacy_avg
    else
      0.0
    end
  end

  defp calculate_error_rate_improvement(reqllm_metrics, legacy_metrics) do
    reqllm_error_rate = Map.get(reqllm_metrics, :error_rate, 0.0)
    legacy_error_rate = Map.get(legacy_metrics, :error_rate, 0.0)

    if legacy_error_rate > 0 do
      (legacy_error_rate - reqllm_error_rate) / legacy_error_rate
    else
      0.0
    end
  end

  defp calculate_throughput_improvement(reqllm_metrics, legacy_metrics) do
    reqllm_requests = Map.get(reqllm_metrics, :total_requests, 0)
    legacy_requests = Map.get(legacy_metrics, :total_requests, 0)

    if legacy_requests > 0 do
      (reqllm_requests - legacy_requests) / legacy_requests
    else
      0.0
    end
  end

  defp calculate_detailed_comparison(reqllm_metrics, legacy_metrics) do
    %{
      latency: %{
        reqllm: get_in(reqllm_metrics, [:latency_stats, :avg]) || 0,
        legacy: get_in(legacy_metrics, [:latency_stats, :avg]) || 0,
        improvement_percent: calculate_latency_improvement(reqllm_metrics, legacy_metrics) * 100
      },
      error_rate: %{
        reqllm: Map.get(reqllm_metrics, :error_rate, 0.0),
        legacy: Map.get(legacy_metrics, :error_rate, 0.0),
        improvement_percent: calculate_error_rate_improvement(reqllm_metrics, legacy_metrics) * 100
      },
      throughput: %{
        reqllm: Map.get(reqllm_metrics, :total_requests, 0),
        legacy: Map.get(legacy_metrics, :total_requests, 0),
        improvement_percent: calculate_throughput_improvement(reqllm_metrics, legacy_metrics) * 100
      },
      streaming: %{
        reqllm_success_rate: Map.get(reqllm_metrics, :streaming_success_rate, 1.0),
        legacy_success_rate: Map.get(legacy_metrics, :streaming_success_rate, 1.0)
      }
    }
  end

  defp cleanup_old_metrics(state) do
    current_time = System.system_time(:second)
    cutoff_time = current_time - (@max_stored_metrics * 60)  # Keep last 24 hours

    # Clean up ReqLLM metrics
    cleaned_reqllm = %{
      requests: Enum.filter(state.reqllm_metrics.requests, &(&1.timestamp > cutoff_time)),
      streaming_events: Enum.filter(state.reqllm_metrics.streaming_events, &(&1.timestamp > cutoff_time)),
      connection_pool_metrics: Enum.filter(state.reqllm_metrics.connection_pool_metrics, &(&1.timestamp > cutoff_time)),
      error_counts: state.reqllm_metrics.error_counts,
      latency_samples: state.reqllm_metrics.latency_samples
    }

    # Clean up legacy metrics
    cleaned_legacy = %{
      requests: Enum.filter(state.legacy_metrics.requests, &(&1.timestamp > cutoff_time)),
      streaming_events: Enum.filter(state.legacy_metrics.streaming_events, &(&1.timestamp > cutoff_time)),
      error_counts: state.legacy_metrics.error_counts,
      latency_samples: state.legacy_metrics.latency_samples
    }

    %{state |
      reqllm_metrics: cleaned_reqllm,
      legacy_metrics: cleaned_legacy,
      last_cleanup: current_time
    }
  end

  defp schedule_cleanup() do
    # Clean up old metrics every hour
    Process.send_after(self(), :cleanup_old_metrics, 60 * 60 * 1000)
  end
end
