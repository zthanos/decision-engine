defmodule DecisionEngine.StreamManager do
  @moduledoc """
  Manages Server-Sent Event streams for real-time LLM response delivery.

  This GenServer coordinates between LLM client streaming and SSE connections,
  handling the complete lifecycle of streaming sessions including:
  - Stream initialization and session tracking
  - Progressive content accumulation and rendering
  - Event formatting and delivery to SSE clients
  - Proper cleanup and timeout management
  - Error handling and recovery

  Each StreamManager process represents a single streaming session and is
  registered in the DecisionEngine.StreamRegistry for session tracking.
  """

  use GenServer
  require Logger

  alias DecisionEngine.MarkdownRenderer

  @typedoc """
  Stream manager state structure.
  """
  @type state :: %{
    session_id: String.t(),
    sse_pid: pid(),
    accumulated_content: String.t(),
    accumulated_html: String.t(),
    status: :initializing | :streaming | :completed | :error | :timeout,
    start_time: DateTime.t(),
    timeout_ref: reference() | nil,
    # Performance optimization fields
    chunk_count: non_neg_integer(),
    last_chunk_time: DateTime.t() | nil,
    render_mode: :incremental | :batch,
    # Flow control fields
    chunk_timestamps: [integer()],
    flow_control_active: boolean(),
    # Chunk order preservation fields
    next_expected_sequence: non_neg_integer(),
    pending_chunks: %{non_neg_integer() => String.t()},
    max_pending_chunks: non_neg_integer(),
    # Session isolation fields
    error_count: non_neg_integer(),
    max_errors: non_neg_integer(),
    memory_limit_bytes: non_neg_integer(),
    isolation_mode: :strict | :relaxed,
    session_metadata: map()
  }

  @typedoc """
  SSE event structure for client communication.
  """
  @type sse_event :: %{
    event: String.t(),
    data: map()
  }

  # Default timeout for streaming sessions (90 seconds - longer than LLM timeout)
  @default_timeout 90_000

  # Maximum content size to prevent memory issues (1MB)
  @max_content_size 1_048_576

  # Flow control settings to prevent overwhelming clients
  @max_chunks_per_second 50
  @chunk_rate_window_ms 1000

  ## Public API

  @doc """
  Starts a new StreamManager for the given session.

  ## Parameters
  - session_id: Unique identifier for the streaming session
  - sse_pid: Process ID of the SSE connection handler
  - opts: Optional configuration (timeout, max_content_size)

  ## Returns
  - {:ok, pid} on successful start
  - {:error, reason} if start fails
  """
  @spec start_link(String.t(), pid(), keyword()) :: GenServer.on_start()
  def start_link(session_id, sse_pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {session_id, sse_pid, opts}, name: via_tuple(session_id))
  end

  @doc """
  Initiates streaming processing for a session.

  ## Parameters
  - session_id: The streaming session identifier
  - signals: Extracted signals from scenario processing
  - decision_result: Result from rule engine evaluation
  - config: LLM client configuration
  - domain: The domain being processed

  ## Returns
  - :ok if streaming started successfully
  - {:error, reason} if session not found or start failed
  """
  @spec stream_processing(String.t(), map(), map(), map(), atom()) :: :ok | {:error, term()}
  def stream_processing(session_id, signals, decision_result, config, domain) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :stream_not_found}
      pid -> GenServer.cast(pid, {:start_streaming, signals, decision_result, config, domain})
    end
  end

  @doc """
  Cancels an active streaming session.

  ## Parameters
  - session_id: The session to cancel

  ## Returns
  - :ok if cancellation initiated
  - {:error, :not_found} if session doesn't exist
  """
  @spec cancel_stream(String.t()) :: :ok | {:error, :not_found}
  def cancel_stream(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, :cancel_stream)
    end
  end

  @doc """
  Gets the current status of a streaming session.

  ## Parameters
  - session_id: The session to check

  ## Returns
  - {:ok, status} where status is one of the defined status atoms
  - {:error, :not_found} if session doesn't exist
  """
  @spec get_stream_status(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_stream_status(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_status)
    end
  end

  @doc """
  Lists all active streaming sessions.

  ## Returns
  - List of session IDs for currently active streams
  """
  @spec list_active_sessions() :: [String.t()]
  def list_active_sessions do
    Registry.select(DecisionEngine.StreamRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
  end

  @doc """
  Gets session metrics for monitoring and isolation validation.

  ## Parameters
  - session_id: The session to get metrics for

  ## Returns
  - {:ok, metrics} with session metrics map
  - {:error, :not_found} if session doesn't exist
  """
  @spec get_session_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session_metrics(session_id) do
    case GenServer.whereis(via_tuple(session_id)) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_session_metrics)
    end
  end

  ## GenServer Callbacks

  @impl true
  def init({session_id, sse_pid, opts}) do
    # Set up process monitoring
    Process.monitor(sse_pid)

    # Configure timeout
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    timeout_ref = Process.send_after(self(), :timeout, timeout)

    state = %{
      session_id: session_id,
      sse_pid: sse_pid,
      accumulated_content: "",
      accumulated_html: "",
      status: :initializing,
      start_time: DateTime.utc_now(),
      timeout_ref: timeout_ref,
      # Performance optimization fields
      chunk_count: 0,
      last_chunk_time: nil,
      render_mode: :incremental,
      # Flow control fields
      chunk_timestamps: [],
      flow_control_active: false,
      # Chunk order preservation fields
      next_expected_sequence: 0,
      pending_chunks: %{},
      max_pending_chunks: Keyword.get(opts, :max_pending_chunks, 100),
      # Session isolation fields
      error_count: 0,
      max_errors: Keyword.get(opts, :max_errors, 5),
      memory_limit_bytes: Keyword.get(opts, :memory_limit_bytes, @max_content_size),
      isolation_mode: Keyword.get(opts, :isolation_mode, :strict),
      session_metadata: %{
        created_at: DateTime.utc_now(),
        process_pid: self(),
        node: Node.self()
      }
    }

    Logger.info("StreamManager started for session #{session_id}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:start_streaming, signals, decision_result, config, domain}, state) do
    Logger.info("Starting streaming for session #{state.session_id}, domain: #{domain}")

    # Record session start for performance monitoring
    provider = Map.get(config, :provider, :unknown)
    DecisionEngine.StreamingPerformanceMonitor.record_session_start(state.session_id, provider)

    # Send initial processing event
    send_sse_event(state.sse_pid, "processing_started", %{
      domain: domain,
      session_id: state.session_id,
      timestamp: DateTime.utc_now()
    })

    # Start LLM streaming (this would be implemented in LLMClient)
    # For now, we'll simulate the streaming process
    start_llm_streaming(signals, decision_result, config, domain)
    {:noreply, %{state | status: :streaming}}
  end

  @impl true
  def handle_cast(:cancel_stream, state) do
    Logger.info("Cancelling stream for session #{state.session_id}")

    send_sse_event(state.sse_pid, "stream_cancelled", %{
      session_id: state.session_id,
      timestamp: DateTime.utc_now()
    })

    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call(:get_session_metrics, _from, state) do
    metrics = build_session_metrics(state)
    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_info({:chunk, content}, state) do
    # Handle unsequenced chunks (backward compatibility)
    handle_chunk_with_sequence(content, state.chunk_count, state)
  end

  @impl true
  def handle_info({:sequenced_chunk, content, sequence_number}, state) do
    # Handle sequenced chunks with order preservation
    handle_chunk_with_sequence(content, sequence_number, state)
  end

  @impl true
  def handle_info({:delayed_chunk, content}, state) do
    # Process delayed chunk (flow control mechanism)
    handle_info({:chunk, content}, state)
  end

  @impl true
  def handle_info({:delayed_sequenced_chunk, content, sequence_number}, state) do
    # Process delayed sequenced chunk (flow control mechanism)
    handle_info({:sequenced_chunk, content, sequence_number}, state)
  end

  @impl true
  def handle_info({:complete}, state) do
    Logger.info("Stream completed for session #{state.session_id}")

    # Record session end for performance monitoring
    DecisionEngine.StreamingPerformanceMonitor.record_session_end(state.session_id)

    # Render final markdown content for proper formatting
    final_html = MarkdownRenderer.render_to_html!(state.accumulated_content)

    # Calculate performance metrics
    duration_ms = DateTime.diff(DateTime.utc_now(), state.start_time, :millisecond)
    avg_chunk_time = if state.chunk_count > 0, do: duration_ms / state.chunk_count, else: 0.0

    # Send completion event with performance metrics
    send_sse_event_fast(state.sse_pid, "processing_complete", %{
      final_content: state.accumulated_content,
      final_html: final_html,
      session_id: state.session_id,
      timestamp: DateTime.utc_now(),
      duration_ms: duration_ms,
      chunk_count: state.chunk_count,
      avg_chunk_processing_ms: Float.round(avg_chunk_time, 2)
    })

    {:stop, :normal, %{state | status: :completed}}
  end

  @impl true
  def handle_info({:error, reason}, state) do
    # Use enhanced error handling with session isolation
    case DecisionEngine.StreamingErrorHandler.handle_streaming_error(
      state.session_id,
      reason,
      get_session_provider(state),
      self(),
      []
    ) do
      {:ok, :recovered} ->
        Logger.info("Error recovered for session #{state.session_id}")
        {:noreply, state}

      {:ok, :fallback} ->
        Logger.info("Fallback activated for session #{state.session_id}")
        {:noreply, %{state | status: :error}}

      {:error, :session_terminated} ->
        Logger.error("Session #{state.session_id} terminated due to error handling")
        {:stop, :normal, state}

      {:error, _reason} ->
        # Fall back to original error handling
        handle_session_error(reason, state)
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("Stream timeout for session #{state.session_id}")

    send_sse_event(state.sse_pid, "stream_timeout", %{
      session_id: state.session_id,
      timestamp: DateTime.utc_now(),
      partial_content: state.accumulated_content,
      partial_html: state.accumulated_html
    })

    {:stop, :normal, %{state | status: :timeout}}
  end

  @impl true
  def handle_info({:retry_streaming, session_id, provider, opts}, state) do
    Logger.info("Retrying streaming for session #{session_id} with provider #{provider}")

    # Attempt to restart streaming with the same configuration
    # This would typically involve calling the LLM client again
    send_sse_event_fast(state.sse_pid, "retry_attempt", %{
      session_id: session_id,
      provider: provider,
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:fallback_to_simulation, session_id}, state) do
    Logger.info("Activating simulation fallback for session #{session_id}")

    # Start simulation streaming as fallback
    spawn_link(fn ->
      simulate_streaming_response(state.sse_pid, session_id)
    end)

    {:noreply, %{state | status: :streaming}}
  end

  @impl true
  def handle_info({:fallback_to_cache, session_id}, state) do
    Logger.info("Activating cache fallback for session #{session_id}")

    # Use cached response if available
    send_sse_event_fast(state.sse_pid, "fallback_cache", %{
      session_id: session_id,
      message: "Using cached response due to streaming unavailability",
      timestamp: DateTime.utc_now()
    })

    {:noreply, %{state | status: :streaming}}
  end

  @impl true
  def handle_info({:fallback_error_response, session_id, error_response}, state) do
    Logger.info("Sending error response fallback for session #{session_id}")

    send_sse_event_fast(state.sse_pid, "fallback_error", error_response)

    {:noreply, %{state | status: :error}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.info("SSE connection closed for session #{state.session_id}: #{inspect(reason)}")

    # Clean up backpressure tracking
    DecisionEngine.StreamingBackpressureHandler.remove_client(state.session_id)

    {:stop, :normal, state}
  end

  # Unified chunk handling with sequence tracking
  defp handle_chunk_with_sequence(content, sequence_number, state) do
    chunk_start_time = System.monotonic_time(:microsecond)

    # Check if this is the next expected chunk in sequence
    if sequence_number == state.next_expected_sequence do
      # Process this chunk immediately and check for pending chunks
      process_chunk_in_order(content, sequence_number, state, chunk_start_time)
    else
      # Store out-of-order chunk for later processing
      handle_out_of_order_chunk(content, sequence_number, state)
    end
  end

  # Process chunk in correct order and check for subsequent pending chunks
  defp process_chunk_in_order(content, sequence_number, state, chunk_start_time) do
    # Session isolation: Check memory limits before processing
    case check_session_memory_usage(state) do
      {:error, :memory_limit_exceeded} ->
        handle_session_error(:memory_limit_exceeded, state)

      {:ok, _current_memory} ->
        # Fast content size check (legacy compatibility)
        new_content_size = byte_size(state.accumulated_content) + byte_size(content)

        if new_content_size > @max_content_size do
          Logger.warning("Content size limit exceeded for session #{state.session_id}")
          handle_session_error(:content_size_limit_exceeded, state)
        else
          process_chunk_with_isolation_checks(content, sequence_number, state, chunk_start_time)
        end
    end
  end

  # Process chunk with full isolation checks
  defp process_chunk_with_isolation_checks(content, sequence_number, state, chunk_start_time) do
    try do
      # Enhanced backpressure handling - temporarily bypassed for debugging
      # case DecisionEngine.StreamingBackpressureHandler.should_send_chunk(
      #   state.session_id,
      #   byte_size(content),
      #   []
      # ) do
      #   {:ok, :send} ->
      # Temporarily bypass backpressure for debugging
          # Process this chunk and any subsequent pending chunks in order
          {final_content, final_html, processed_chunks, updated_pending} =
            process_chunks_in_sequence(content, sequence_number, state)

          # Send all processed chunks in order with session isolation
          Enum.each(processed_chunks, fn {chunk_content, chunk_html} ->
            send_sse_event_isolated(state.sse_pid, "content_chunk", %{
              content: chunk_content,
              rendered_html: chunk_html,
              session_id: state.session_id
            }, state.isolation_mode)

            # Record chunk sent for backpressure tracking
            DecisionEngine.StreamingBackpressureHandler.record_chunk_sent(
              state.session_id,
              byte_size(chunk_content)
            )
          end)

          chunk_end_time = System.monotonic_time(:microsecond)
          processing_time_us = chunk_end_time - chunk_start_time

          # Record performance metrics for monitoring
          provider = get_session_provider(state)
          DecisionEngine.StreamingPerformanceMonitor.record_chunk_latency(
            state.session_id,
            provider,
            byte_size(content),
            processing_time_us
          )

          # Log if processing takes longer than 10ms (10,000 microseconds)
          if processing_time_us > 10_000 do
            Logger.warning("Chunk processing exceeded 10ms: #{processing_time_us}μs for session #{state.session_id}")
          end

          new_sequence = sequence_number + length(processed_chunks)

          {:noreply, %{state |
            accumulated_content: final_content,
            accumulated_html: final_html,
            chunk_count: state.chunk_count + length(processed_chunks),
            last_chunk_time: DateTime.utc_now(),
            next_expected_sequence: new_sequence,
            pending_chunks: updated_pending
          }}

        # {:ok, {:delay, delay_ms}} ->
        #   # Backpressure detected: delay this chunk
        #   Process.send_after(self(), {:delayed_sequenced_chunk, content, sequence_number}, delay_ms)
        #   {:noreply, state}

        # {:error, :backpressure} ->
        #   # Severe backpressure: handle as error
        #   Logger.warning("Severe backpressure detected for session #{state.session_id}")
        #   handle_session_error(:backpressure_limit_exceeded, state)
      # end
    rescue
      error ->
        # Session isolation: Handle errors without affecting other sessions
        Logger.error("Session #{state.session_id} chunk processing error: #{inspect(error)}")
        handle_session_error({:chunk_processing_error, error}, state)
    end
  end

  # Handle out-of-order chunks by storing them for later processing
  defp handle_out_of_order_chunk(content, sequence_number, state) do
    # Check if we have too many pending chunks (potential memory issue)
    if map_size(state.pending_chunks) >= state.max_pending_chunks do
      Logger.warning("Too many pending chunks for session #{state.session_id}, dropping chunk #{sequence_number}")
      {:noreply, state}
    else
      Logger.debug("Storing out-of-order chunk #{sequence_number} for session #{state.session_id} (expected: #{state.next_expected_sequence})")

      updated_pending = Map.put(state.pending_chunks, sequence_number, content)

      {:noreply, %{state | pending_chunks: updated_pending}}
    end
  end

  # Process chunks in sequence, including any pending chunks that are now ready
  defp process_chunks_in_sequence(content, sequence_number, state) do
    # Start with the current chunk
    initial_content = state.accumulated_content <> content
    initial_html = state.accumulated_html <> escape_html_fast(content)
    processed_chunks = [{content, escape_html_fast(content)}]

    # Process any subsequent pending chunks in order
    process_pending_chunks(initial_content, initial_html, processed_chunks, sequence_number + 1, state.pending_chunks)
  end

  # Recursively process pending chunks in order
  defp process_pending_chunks(content, html, processed_chunks, next_sequence, pending_chunks) do
    case Map.get(pending_chunks, next_sequence) do
      nil ->
        # No more consecutive chunks available
        {content, html, processed_chunks, pending_chunks}

      chunk_content ->
        # Found the next chunk in sequence
        new_content = content <> chunk_content
        escaped_chunk = escape_html_fast(chunk_content)
        new_html = html <> escaped_chunk
        new_processed = processed_chunks ++ [{chunk_content, escaped_chunk}]
        updated_pending = Map.delete(pending_chunks, next_sequence)

        # Continue processing the next sequence number
        process_pending_chunks(new_content, new_html, new_processed, next_sequence + 1, updated_pending)
    end
  end





  @impl true
  def terminate(reason, state) do
    Logger.info("StreamManager terminating for session #{state.session_id}: #{inspect(reason)}")

    # Cancel timeout if still active
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    :ok
  end

  ## Private Functions

  # Session isolation and resource management

  # Check if session has exceeded error limits
  defp check_session_error_limits(state) do
    if state.error_count >= state.max_errors do
      Logger.error("Session #{state.session_id} exceeded error limit (#{state.error_count}/#{state.max_errors})")
      {:error, :error_limit_exceeded}
    else
      :ok
    end
  end

  # Check session memory usage
  defp check_session_memory_usage(state) do
    current_memory = byte_size(state.accumulated_content) +
                    byte_size(state.accumulated_html) +
                    (map_size(state.pending_chunks) * 100)  # Estimate pending chunks memory

    if current_memory > state.memory_limit_bytes do
      Logger.warning("Session #{state.session_id} exceeded memory limit: #{current_memory} bytes")
      {:error, :memory_limit_exceeded}
    else
      {:ok, current_memory}
    end
  end

  # Increment error count for session
  defp increment_session_error_count(state) do
    %{state | error_count: state.error_count + 1}
  end

  # Get session isolation metrics from state
  defp build_session_metrics(state) do
    current_memory = byte_size(state.accumulated_content) +
                    byte_size(state.accumulated_html) +
                    (map_size(state.pending_chunks) * 100)

    %{
      session_id: state.session_id,
      status: state.status,
      chunk_count: state.chunk_count,
      error_count: state.error_count,
      memory_usage_bytes: current_memory,
      pending_chunks_count: map_size(state.pending_chunks),
      uptime_ms: DateTime.diff(DateTime.utc_now(), state.start_time, :millisecond),
      isolation_mode: state.isolation_mode
    }
  end

  # Get provider from session metadata (fallback to unknown)
  defp get_session_provider(state) do
    Map.get(state.session_metadata, :provider, :unknown)
  end

  # Handle session-specific errors with isolation
  defp handle_session_error(reason, state) do
    updated_state = increment_session_error_count(state)

    # Record error for performance monitoring
    provider = get_session_provider(state)
    error_type = case reason do
      :timeout -> :timeout
      {:timeout, _} -> :timeout
      {:chunk_processing_error, _} -> :processing
      _ -> :general
    end
    DecisionEngine.StreamingPerformanceMonitor.record_error(state.session_id, error_type, provider)

    # Log error with session context
    Logger.error("Session #{state.session_id} error: #{inspect(reason)} (error #{updated_state.error_count}/#{state.max_errors})")

    # Check if we should terminate this session
    case check_session_error_limits(updated_state) do
      :ok ->
        # Continue with error state but don't terminate
        send_sse_event_fast(state.sse_pid, "session_error", %{
          reason: reason,
          session_id: state.session_id,
          error_count: updated_state.error_count,
          recoverable: true
        })
        {:noreply, %{updated_state | status: :error}}

      {:error, :error_limit_exceeded} ->
        # Terminate session due to too many errors
        send_sse_event_fast(state.sse_pid, "session_terminated", %{
          reason: :error_limit_exceeded,
          session_id: state.session_id,
          error_count: updated_state.error_count
        })
        {:stop, :normal, updated_state}
    end
  end

  # Fast HTML escaping optimized for streaming
  defp escape_html_fast(content) do
    # Use Phoenix.HTML for safety but optimize for common cases
    case content do
      "" -> ""
      content when byte_size(content) < 1024 ->
        # Fast path for small chunks
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
      content ->
        # For larger chunks, still escape but log performance
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end

  # Optimized SSE event sending with minimal payload
  defp send_sse_event_fast(sse_pid, event_type, data) do
    # Send minimal data structure to reduce serialization overhead
    send(sse_pid, {:sse_event, event_type, data})
  end

  # Session-isolated SSE event sending with error handling
  defp send_sse_event_isolated(sse_pid, event_type, data, isolation_mode) do
    case isolation_mode do
      :strict ->
        # In strict mode, catch any errors to prevent session interference
        try do
          send(sse_pid, {:sse_event, event_type, data})
        rescue
          error ->
            Logger.warning("Failed to send SSE event in strict isolation mode: #{inspect(error)}")
            :error
        catch
          :exit, reason ->
            Logger.warning("SSE process exited in strict isolation mode: #{inspect(reason)}")
            :error
        end

      :relaxed ->
        # In relaxed mode, send normally (faster but less isolated)
        send(sse_pid, {:sse_event, event_type, data})
    end
  end

  # Flow control to prevent overwhelming clients
  defp check_flow_control(current_time, timestamps, _flow_control_active) do
    # Remove timestamps older than the rate window
    window_start = current_time - @chunk_rate_window_ms
    recent_timestamps = Enum.filter(timestamps, &(&1 >= window_start))

    # Check if we're exceeding the rate limit
    if length(recent_timestamps) >= @max_chunks_per_second do
      # Rate limit exceeded - activate flow control
      {false, recent_timestamps, true}
    else
      # Rate is acceptable - allow processing
      {true, [current_time | recent_timestamps], false}
    end
  end

  defp via_tuple(session_id) do
    {:via, Registry, {DecisionEngine.StreamRegistry, session_id}}
  end

  defp send_sse_event(sse_pid, event_type, data) do
    send(sse_pid, {:sse_event, event_type, data})
  end

  # Integrate with LLMClient for actual streaming
  defp start_llm_streaming(signals, decision_result, config, domain) do
    case DecisionEngine.LLMClient.stream_justification(signals, decision_result, config, domain, self()) do
      :ok ->
        Logger.debug("LLM streaming started successfully for domain #{domain}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to start LLM streaming for domain #{domain}: #{inspect(reason)}")
        send(self(), {:error, reason})
        {:error, reason}
    end
  end

  # Simulate streaming response as fallback
  defp simulate_streaming_response(sse_pid, session_id) do
    try do
      # Simulate realistic streaming chunks with delays
      chunks = [
        "## Analysis Results\n\n",
        "Based on your scenario, I can provide the following recommendations:\n\n",
        "### Key Considerations\n\n",
        "- **Technical Requirements**: Your requirements align well with available solutions\n",
        "- **Implementation Approach**: Consider a phased rollout strategy\n",
        "- **Risk Assessment**: Low to moderate risk with proper planning\n\n",
        "### Recommended Solution\n\n",
        "1. **Phase 1**: Initial implementation with core features\n",
        "2. **Phase 2**: Extended functionality and integration\n",
        "3. **Phase 3**: Optimization and scaling\n\n",
        "### Next Steps\n\n",
        "- Review the recommended approach\n",
        "- Consider implementation timeline\n",
        "- Plan for testing and validation\n\n",
        "*Note: This is a fallback response due to temporary streaming unavailability.*"
      ]

      Enum.each(chunks, fn chunk ->
        Process.sleep(80 + :rand.uniform(120))  # Realistic delay variation
        send(sse_pid, {:sse_event, "content_chunk", %{
          content: chunk,
          rendered_html: escape_html_fast(chunk),
          session_id: session_id
        }})
      end)

      Process.sleep(100)
      send(sse_pid, {:sse_event, "processing_complete", %{
        final_content: Enum.join(chunks, ""),
        session_id: session_id,
        timestamp: DateTime.utc_now(),
        fallback_used: true
      }})
    rescue
      error ->
        Logger.error("Simulation fallback error for session #{session_id}: #{inspect(error)}")
        send(sse_pid, {:sse_event, "stream_error", %{
          session_id: session_id,
          error: "Fallback simulation failed"
        }})
    end
  end
end
