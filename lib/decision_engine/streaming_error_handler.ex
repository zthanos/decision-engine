# lib/decision_engine/streaming_error_handler.ex
defmodule DecisionEngine.StreamingErrorHandler do
  @moduledoc """
  Enhanced error handling and recovery for streaming operations with session isolation.

  This module provides comprehensive error handling that ensures failures in one
  streaming session do not affect other concurrent sessions. It includes:
  - Session-isolated error handling
  - Automatic recovery mechanisms for transient failures
  - Graceful fallback strategies for streaming failures
  - Circuit breaker patterns for provider failures
  - Error metrics and monitoring integration
  """

  use GenServer
  require Logger

  alias DecisionEngine.StreamingRetryHandler
  alias DecisionEngine.StreamingPerformanceMonitor

  @typedoc """
  Error handling configuration for streaming sessions.
  """
  @type error_config :: %{
    session_isolation: :strict | :relaxed,
    max_session_errors: non_neg_integer(),
    error_window_ms: non_neg_integer(),
    circuit_breaker_enabled: boolean(),
    circuit_breaker_threshold: non_neg_integer(),
    circuit_breaker_timeout_ms: non_neg_integer(),
    fallback_enabled: boolean(),
    fallback_strategy: :simulation | :cached_response | :error_response,
    retry_config: StreamingRetryHandler.retry_config()
  }

  @typedoc """
  Session error state tracking.
  """
  @type session_error_state :: %{
    session_id: String.t(),
    error_count: non_neg_integer(),
    last_error_time: integer(),
    error_history: [map()],
    circuit_breaker_state: :closed | :open | :half_open,
    circuit_breaker_opened_at: integer() | nil,
    recovery_attempts: non_neg_integer(),
    isolation_violations: non_neg_integer()
  }

  @typedoc """
  Provider circuit breaker state.
  """
  @type provider_circuit_state :: %{
    provider: atom(),
    state: :closed | :open | :half_open,
    failure_count: non_neg_integer(),
    last_failure_time: integer(),
    opened_at: integer() | nil,
    success_count: non_neg_integer()
  }

  # Default error handling configuration
  @default_config %{
    session_isolation: :strict,
    max_session_errors: 5,
    error_window_ms: 60_000,  # 1 minute
    circuit_breaker_enabled: true,
    circuit_breaker_threshold: 3,
    circuit_breaker_timeout_ms: 30_000,  # 30 seconds
    fallback_enabled: true,
    fallback_strategy: :simulation,
    retry_config: StreamingRetryHandler.create_config()
  }

  # Circuit breaker thresholds per provider
  @provider_circuit_thresholds %{
    openai: 5,
    anthropic: 5,
    ollama: 3,
    lm_studio: 3,
    custom: 5
  }

  ## Public API

  @doc """
  Starts the streaming error handler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Handles a streaming error with session isolation and recovery.

  ## Parameters
  - session_id: The streaming session that encountered the error
  - error: The error that occurred
  - provider: The LLM provider being used
  - stream_pid: The process handling the stream
  - opts: Additional options for error handling

  ## Returns
  - {:ok, :recovered} if error was handled and recovery initiated
  - {:ok, :fallback} if fallback strategy was applied
  - {:error, :session_terminated} if session should be terminated
  - {:error, reason} if error handling failed
  """
  @spec handle_streaming_error(String.t(), term(), atom(), pid(), keyword()) ::
    {:ok, :recovered | :fallback} | {:error, :session_terminated | term()}
  def handle_streaming_error(session_id, error, provider, stream_pid, opts \\ []) do
    GenServer.call(__MODULE__, {
      :handle_error,
      session_id,
      error,
      provider,
      stream_pid,
      opts
    })
  end

  @doc """
  Checks if a provider's circuit breaker is open.

  ## Parameters
  - provider: The LLM provider to check

  ## Returns
  - true if circuit breaker is open (provider unavailable)
  - false if circuit breaker is closed (provider available)
  """
  @spec is_circuit_open?(atom()) :: boolean()
  def is_circuit_open?(provider) do
    GenServer.call(__MODULE__, {:is_circuit_open, provider})
  end

  @doc """
  Records a successful operation for circuit breaker management.

  ## Parameters
  - provider: The LLM provider that succeeded
  - session_id: The session that succeeded (optional)
  """
  @spec record_success(atom(), String.t() | nil) :: :ok
  def record_success(provider, session_id \\ nil) do
    GenServer.cast(__MODULE__, {:record_success, provider, session_id})
  end

  @doc """
  Gets error statistics for a session.

  ## Parameters
  - session_id: The session to get statistics for

  ## Returns
  - {:ok, stats} with error statistics
  - {:error, :not_found} if session not found
  """
  @spec get_session_error_stats(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session_error_stats(session_id) do
    GenServer.call(__MODULE__, {:get_session_stats, session_id})
  end

  @doc """
  Gets provider circuit breaker status.

  ## Returns
  - Map of provider states and statistics
  """
  @spec get_provider_status() :: map()
  def get_provider_status do
    GenServer.call(__MODULE__, :get_provider_status)
  end

  @doc """
  Resets circuit breaker for a provider (admin function).

  ## Parameters
  - provider: The provider to reset
  """
  @spec reset_circuit_breaker(atom()) :: :ok
  def reset_circuit_breaker(provider) do
    GenServer.cast(__MODULE__, {:reset_circuit_breaker, provider})
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, @default_config)

    state = %{
      config: config,
      session_states: %{},
      provider_circuits: %{},
      error_metrics: %{
        total_errors: 0,
        recovered_errors: 0,
        fallback_activations: 0,
        session_terminations: 0
      }
    }

    Logger.info("StreamingErrorHandler started with config: #{inspect(config)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:handle_error, session_id, error, provider, stream_pid, opts}, _from, state) do
    # Handle error with session isolation
    case handle_error_with_isolation(session_id, error, provider, stream_pid, opts, state) do
      {:ok, action, new_state} ->
        {:reply, {:ok, action}, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call({:is_circuit_open, provider}, _from, state) do
    circuit_state = get_provider_circuit_state(provider, state)
    is_open = circuit_state.state == :open

    # Check if circuit should transition from open to half-open
    if is_open and should_try_half_open?(circuit_state, state.config) do
      new_state = update_provider_circuit_state(provider, %{circuit_state | state: :half_open}, state)
      {:reply, false, new_state}  # Allow one test request
    else
      {:reply, is_open, state}
    end
  end

  @impl true
  def handle_call({:get_session_stats, session_id}, _from, state) do
    case Map.get(state.session_states, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session_state ->
        stats = build_session_error_stats(session_state)
        {:reply, {:ok, stats}, state}
    end
  end

  @impl true
  def handle_call(:get_provider_status, _from, state) do
    provider_status = build_provider_status(state)
    {:reply, provider_status, state}
  end

  @impl true
  def handle_cast({:record_success, provider, session_id}, state) do
    new_state = record_provider_success(provider, session_id, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:reset_circuit_breaker, provider}, state) do
    Logger.info("Manually resetting circuit breaker for provider: #{provider}")

    circuit_state = %{
      provider: provider,
      state: :closed,
      failure_count: 0,
      last_failure_time: 0,
      opened_at: nil,
      success_count: 0
    }

    new_state = update_provider_circuit_state(provider, circuit_state, state)
    {:noreply, new_state}
  end

  ## Private Functions

  # Handle error with comprehensive session isolation
  defp handle_error_with_isolation(session_id, error, provider, stream_pid, opts, state) do
    Logger.warning("Handling streaming error for session #{session_id}, provider #{provider}: #{inspect(error)}")

    # Update error metrics
    new_state = update_error_metrics(state, :total_errors)

    # Get or create session error state
    session_state = get_or_create_session_state(session_id, new_state)

    # Classify the error
    error_type = StreamingRetryHandler.classify_error(error)

    # Record error in session state
    updated_session_state = record_session_error(session_state, error, error_type)

    # Check session error limits
    case check_session_error_limits(updated_session_state, new_state.config) do
      {:ok, :continue} ->
        # Session can continue, attempt recovery
        attempt_error_recovery(session_id, error, error_type, provider, stream_pid, opts, updated_session_state, new_state)

      {:error, :session_limit_exceeded} ->
        # Session has exceeded error limits, terminate with isolation
        terminate_session_with_isolation(session_id, updated_session_state, new_state)
    end
  end

  # Attempt error recovery with various strategies
  defp attempt_error_recovery(session_id, error, error_type, provider, stream_pid, opts, session_state, state) do
    # Update provider circuit breaker
    new_state = record_provider_failure(provider, error_type, state)

    # Check if circuit breaker is open
    circuit_state = get_provider_circuit_state(provider, new_state)

    case circuit_state.state do
      :open ->
        # Circuit is open, use fallback strategy
        apply_fallback_strategy(session_id, provider, stream_pid, session_state, new_state)

      _ ->
        # Circuit is closed or half-open, attempt retry
        attempt_retry_recovery(session_id, error, error_type, provider, stream_pid, opts, session_state, new_state)
    end
  end

  # Attempt recovery through retry mechanism
  defp attempt_retry_recovery(session_id, error, error_type, provider, stream_pid, opts, session_state, state) do
    retry_config = state.config.retry_config
    attempt_count = session_state.recovery_attempts + 1

    case StreamingRetryHandler.should_retry(error, attempt_count, retry_config) do
      {:delay, delay_ms} ->
        Logger.info("Scheduling retry for session #{session_id} after #{delay_ms}ms (attempt #{attempt_count})")

        # Schedule retry with isolation
        schedule_isolated_retry(session_id, provider, stream_pid, delay_ms, opts)

        # Update session state
        updated_session_state = %{session_state | recovery_attempts: attempt_count}
        final_state = update_session_state(session_id, updated_session_state, state)
        final_state = update_error_metrics(final_state, :recovered_errors)

        {:ok, :recovered, final_state}

      :stop ->
        Logger.warning("Retry limit exceeded for session #{session_id}, applying fallback")
        apply_fallback_strategy(session_id, provider, stream_pid, session_state, state)
    end
  end

  # Apply fallback strategy when recovery fails
  defp apply_fallback_strategy(session_id, provider, stream_pid, session_state, state) do
    if state.config.fallback_enabled do
      Logger.info("Applying fallback strategy for session #{session_id}: #{state.config.fallback_strategy}")

      case state.config.fallback_strategy do
        :simulation ->
          # Use simulation fallback
          send(stream_pid, {:fallback_to_simulation, session_id})

        :cached_response ->
          # Use cached response if available
          send(stream_pid, {:fallback_to_cache, session_id})

        :error_response ->
          # Send structured error response
          send(stream_pid, {:fallback_error_response, session_id, build_error_response(provider)})
      end

      updated_session_state = %{session_state | recovery_attempts: session_state.recovery_attempts + 1}
      final_state = update_session_state(session_id, updated_session_state, state)
      final_state = update_error_metrics(final_state, :fallback_activations)

      {:ok, :fallback, final_state}
    else
      # Fallback disabled, terminate session
      terminate_session_with_isolation(session_id, session_state, state)
    end
  end

  # Terminate session with proper isolation
  defp terminate_session_with_isolation(session_id, session_state, state) do
    Logger.error("Terminating session #{session_id} due to error limits exceeded")

    # Record session termination metrics
    StreamingPerformanceMonitor.record_session_end(session_id)

    # Remove session state to prevent memory leaks
    final_state = remove_session_state(session_id, state)
    final_state = update_error_metrics(final_state, :session_terminations)

    {:error, :session_terminated, final_state}
  end

  # Schedule retry with session isolation
  defp schedule_isolated_retry(session_id, provider, stream_pid, delay_ms, opts) do
    # Use a separate process to avoid blocking the error handler
    spawn_link(fn ->
      try do
        Process.sleep(delay_ms)

        # Check if session is still active before retrying
        case DecisionEngine.StreamManager.get_stream_status(session_id) do
          {:ok, status} when status in [:streaming, :error] ->
            # Session is still active, attempt retry
            send(stream_pid, {:retry_streaming, session_id, provider, opts})

          _ ->
            # Session is no longer active, skip retry
            Logger.debug("Skipping retry for inactive session: #{session_id}")
        end
      rescue
        error ->
          Logger.error("Error in retry scheduler for session #{session_id}: #{inspect(error)}")
      end
    end)
  end

  # Get or create session error state
  defp get_or_create_session_state(session_id, state) do
    Map.get(state.session_states, session_id, %{
      session_id: session_id,
      error_count: 0,
      last_error_time: 0,
      error_history: [],
      circuit_breaker_state: :closed,
      circuit_breaker_opened_at: nil,
      recovery_attempts: 0,
      isolation_violations: 0
    })
  end

  # Record error in session state
  defp record_session_error(session_state, error, error_type) do
    current_time = System.monotonic_time(:millisecond)

    error_record = %{
      error: error,
      error_type: error_type,
      timestamp: current_time,
      recovery_attempted: false
    }

    # Keep only recent errors (within error window)
    error_window_start = current_time - 60_000  # 1 minute window
    recent_errors = Enum.filter(session_state.error_history, &(&1.timestamp >= error_window_start))

    %{session_state |
      error_count: session_state.error_count + 1,
      last_error_time: current_time,
      error_history: [error_record | recent_errors]
    }
  end

  # Check if session has exceeded error limits
  defp check_session_error_limits(session_state, config) do
    recent_error_count = length(session_state.error_history)

    if recent_error_count >= config.max_session_errors do
      {:error, :session_limit_exceeded}
    else
      {:ok, :continue}
    end
  end

  # Get provider circuit breaker state
  defp get_provider_circuit_state(provider, state) do
    Map.get(state.provider_circuits, provider, %{
      provider: provider,
      state: :closed,
      failure_count: 0,
      last_failure_time: 0,
      opened_at: nil,
      success_count: 0
    })
  end

  # Update provider circuit breaker state
  defp update_provider_circuit_state(provider, circuit_state, state) do
    new_provider_circuits = Map.put(state.provider_circuits, provider, circuit_state)
    %{state | provider_circuits: new_provider_circuits}
  end

  # Record provider failure and update circuit breaker
  defp record_provider_failure(provider, error_type, state) do
    circuit_state = get_provider_circuit_state(provider, state)
    current_time = System.monotonic_time(:millisecond)

    # Increment failure count
    new_failure_count = circuit_state.failure_count + 1
    threshold = Map.get(@provider_circuit_thresholds, provider, 5)

    # Check if circuit should open
    new_circuit_state = if new_failure_count >= threshold and circuit_state.state == :closed do
      Logger.warning("Opening circuit breaker for provider #{provider} after #{new_failure_count} failures")

      %{circuit_state |
        state: :open,
        failure_count: new_failure_count,
        last_failure_time: current_time,
        opened_at: current_time,
        success_count: 0
      }
    else
      %{circuit_state |
        failure_count: new_failure_count,
        last_failure_time: current_time
      }
    end

    # Record provider error metrics
    StreamingPerformanceMonitor.record_error("provider_#{provider}", error_type, provider)

    update_provider_circuit_state(provider, new_circuit_state, state)
  end

  # Record provider success and update circuit breaker
  defp record_provider_success(provider, _session_id, state) do
    circuit_state = get_provider_circuit_state(provider, state)
    current_time = System.monotonic_time(:millisecond)

    new_circuit_state = case circuit_state.state do
      :half_open ->
        # Success in half-open state, close the circuit
        Logger.info("Closing circuit breaker for provider #{provider} after successful recovery")

        %{circuit_state |
          state: :closed,
          failure_count: 0,
          success_count: circuit_state.success_count + 1,
          opened_at: nil
        }

      :closed ->
        # Normal success, just increment success count
        %{circuit_state |
          success_count: circuit_state.success_count + 1
        }

      :open ->
        # Success while open (shouldn't happen, but handle gracefully)
        circuit_state
    end

    update_provider_circuit_state(provider, new_circuit_state, state)
  end

  # Check if circuit should transition from open to half-open
  defp should_try_half_open?(circuit_state, config) do
    if circuit_state.state == :open and circuit_state.opened_at do
      current_time = System.monotonic_time(:millisecond)
      time_since_opened = current_time - circuit_state.opened_at
      time_since_opened >= config.circuit_breaker_timeout_ms
    else
      false
    end
  end

  # Update session state
  defp update_session_state(session_id, session_state, state) do
    new_session_states = Map.put(state.session_states, session_id, session_state)
    %{state | session_states: new_session_states}
  end

  # Remove session state
  defp remove_session_state(session_id, state) do
    new_session_states = Map.delete(state.session_states, session_id)
    %{state | session_states: new_session_states}
  end

  # Update error metrics
  defp update_error_metrics(state, metric_type) do
    new_metrics = Map.update!(state.error_metrics, metric_type, &(&1 + 1))
    %{state | error_metrics: new_metrics}
  end

  # Build session error statistics
  defp build_session_error_stats(session_state) do
    %{
      session_id: session_state.session_id,
      error_count: session_state.error_count,
      recent_errors: length(session_state.error_history),
      last_error_time: session_state.last_error_time,
      recovery_attempts: session_state.recovery_attempts,
      isolation_violations: session_state.isolation_violations,
      circuit_breaker_state: session_state.circuit_breaker_state
    }
  end

  # Build provider status summary
  defp build_provider_status(state) do
    provider_status = state.provider_circuits
    |> Enum.map(fn {provider, circuit_state} ->
      {provider, %{
        state: circuit_state.state,
        failure_count: circuit_state.failure_count,
        success_count: circuit_state.success_count,
        last_failure_time: circuit_state.last_failure_time,
        opened_at: circuit_state.opened_at
      }}
    end)
    |> Map.new()

    %{
      providers: provider_status,
      global_metrics: state.error_metrics
    }
  end

  # Build structured error response for fallback
  defp build_error_response(provider) do
    %{
      error: "streaming_unavailable",
      message: "Streaming is temporarily unavailable for provider #{provider}. Please try again later.",
      provider: provider,
      fallback_active: true,
      timestamp: System.system_time(:second)
    }
  end
end
