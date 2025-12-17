defmodule DecisionEngine.ReqLLMChunkProcessor do
  @moduledoc """
  Enhanced chunk processing and flow control for ReqLLM streaming.

  This module provides intelligent chunk ordering, validation, aggregation,
  and backpressure management to ensure reliable streaming performance.

  ## Features
  - Intelligent chunk ordering and sequence validation
  - Backpressure management and flow control
  - Chunk aggregation and validation logic
  - Content integrity checking
  - Performance optimization for high-throughput streaming
  """

  require Logger

  @typedoc """
  Chunk processing state for managing flow control and ordering.
  """
  @type chunk_state :: %{
    session_id: String.t(),
    sequence_counter: integer(),
    pending_chunks: %{integer() => binary()},
    max_pending_chunks: integer(),
    flow_control: %{
      enabled: boolean(),
      max_chunks_per_second: integer(),
      chunk_timestamps: [integer()],
      backpressure_active: boolean(),
      window_size_ms: integer()
    },
    validation: %{
      enabled: boolean(),
      max_chunk_size: integer(),
      total_size_limit: integer(),
      current_total_size: integer(),
      content_encoding: String.t()
    },
    aggregation: %{
      buffer: binary(),
      buffer_size: integer(),
      flush_threshold: integer(),
      flush_interval_ms: integer(),
      last_flush_time: integer()
    }
  }

  # Configuration constants
  @default_max_chunks_per_second 100
  @default_window_size_ms 1000
  @default_max_chunk_size 8192
  @default_total_size_limit 10_485_760  # 10MB
  @default_flush_threshold 4096
  @default_flush_interval_ms 100
  @default_max_pending_chunks 50

  ## Public API

  @doc """
  Initializes chunk processing state for a session.

  ## Parameters
  - session_id: Unique identifier for the streaming session
  - opts: Processing options

  ## Returns
  - chunk_state() with initialized processing state
  """
  @spec init_chunk_state(String.t(), keyword()) :: chunk_state()
  def init_chunk_state(session_id, opts \\ []) do
    %{
      session_id: session_id,
      sequence_counter: 0,
      pending_chunks: %{},
      max_pending_chunks: Keyword.get(opts, :max_pending_chunks, @default_max_pending_chunks),
      flow_control: %{
        enabled: Keyword.get(opts, :enable_flow_control, true),
        max_chunks_per_second: Keyword.get(opts, :max_chunks_per_second, @default_max_chunks_per_second),
        chunk_timestamps: [],
        backpressure_active: false,
        window_size_ms: Keyword.get(opts, :window_size_ms, @default_window_size_ms)
      },
      validation: %{
        enabled: Keyword.get(opts, :enable_validation, true),
        max_chunk_size: Keyword.get(opts, :max_chunk_size, @default_max_chunk_size),
        total_size_limit: Keyword.get(opts, :total_size_limit, @default_total_size_limit),
        current_total_size: 0,
        content_encoding: Keyword.get(opts, :content_encoding, "utf-8")
      },
      aggregation: %{
        buffer: "",
        buffer_size: 0,
        flush_threshold: Keyword.get(opts, :flush_threshold, @default_flush_threshold),
        flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
        last_flush_time: System.monotonic_time(:millisecond)
      }
    }
  end
  @doc """
  Processes an incoming chunk with flow control and validation.

  ## Parameters
  - chunk_data: Binary chunk data
  - sequence_number: Optional sequence number for ordering
  - state: Current chunk processing state

  ## Returns
  - {:ok, processed_chunks, updated_state} on success
  - {:delay, delay_ms, updated_state} if backpressure applied
  - {:error, reason, updated_state} on validation failure
  """
  @spec process_chunk(binary(), integer() | nil, chunk_state()) ::
    {:ok, [binary()], chunk_state()} |
    {:delay, integer(), chunk_state()} |
    {:error, term(), chunk_state()}
  def process_chunk(chunk_data, sequence_number \\ nil, state) do
    current_time = System.monotonic_time(:millisecond)

    # Validate chunk first
    case validate_chunk(chunk_data, state) do
      {:ok, validated_chunk} ->
        # Apply flow control
        case apply_flow_control(state, current_time) do
          {:ok, updated_flow_state} ->
            # Process chunk with ordering
            process_chunk_with_ordering(validated_chunk, sequence_number, state, updated_flow_state, current_time)

          {:delay, delay_ms, updated_flow_state} ->
            # Backpressure detected
            updated_state = %{state | flow_control: updated_flow_state}
            {:delay, delay_ms, updated_state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, validation_error} ->
        Logger.warning("Chunk validation failed for session #{state.session_id}: #{inspect(validation_error)}")
        {:error, validation_error, state}
    end
  end

  @doc """
  Forces flush of aggregated content.

  ## Parameters
  - state: Current chunk processing state

  ## Returns
  - {:ok, flushed_content, updated_state} with any buffered content
  """
  @spec flush_aggregated_content(chunk_state()) :: {:ok, binary(), chunk_state()}
  def flush_aggregated_content(state) do
    current_time = System.monotonic_time(:millisecond)

    flushed_content = state.aggregation.buffer

    updated_aggregation = %{state.aggregation |
      buffer: "",
      buffer_size: 0,
      last_flush_time: current_time
    }

    updated_state = %{state | aggregation: updated_aggregation}

    {:ok, flushed_content, updated_state}
  end

  @doc """
  Checks if aggregated content should be flushed.

  ## Parameters
  - state: Current chunk processing state

  ## Returns
  - true if content should be flushed, false otherwise
  """
  @spec should_flush_content?(chunk_state()) :: boolean()
  def should_flush_content?(state) do
    current_time = System.monotonic_time(:millisecond)

    # Flush if buffer exceeds threshold
    size_threshold_exceeded = state.aggregation.buffer_size >= state.aggregation.flush_threshold

    # Flush if time interval exceeded
    time_threshold_exceeded = (current_time - state.aggregation.last_flush_time) >= state.aggregation.flush_interval_ms

    # Flush if buffer is not empty and time threshold exceeded
    (size_threshold_exceeded or time_threshold_exceeded) and state.aggregation.buffer_size > 0
  end

  @doc """
  Gets current processing metrics for monitoring.

  ## Parameters
  - state: Current chunk processing state

  ## Returns
  - Map with processing metrics
  """
  @spec get_processing_metrics(chunk_state()) :: map()
  def get_processing_metrics(state) do
    current_time = System.monotonic_time(:millisecond)

    %{
      session_id: state.session_id,
      sequence_counter: state.sequence_counter,
      pending_chunks_count: map_size(state.pending_chunks),
      backpressure_active: state.flow_control.backpressure_active,
      current_total_size: state.validation.current_total_size,
      buffer_size: state.aggregation.buffer_size,
      chunks_per_second: calculate_chunks_per_second(state, current_time),
      time_since_last_flush: current_time - state.aggregation.last_flush_time
    }
  end

  ## Private Functions

  # Validate incoming chunk
  defp validate_chunk(chunk_data, state) do
    if state.validation.enabled do
      cond do
        # Check chunk size
        byte_size(chunk_data) > state.validation.max_chunk_size ->
          {:error, {:chunk_too_large, byte_size(chunk_data), state.validation.max_chunk_size}}

        # Check total size limit
        state.validation.current_total_size + byte_size(chunk_data) > state.validation.total_size_limit ->
          {:error, {:total_size_limit_exceeded, state.validation.current_total_size + byte_size(chunk_data)}}

        # Check content encoding
        not String.valid?(chunk_data) ->
          {:error, {:invalid_encoding, state.validation.content_encoding}}

        true ->
          {:ok, chunk_data}
      end
    else
      {:ok, chunk_data}
    end
  end

  # Apply flow control to prevent overwhelming downstream
  defp apply_flow_control(state, current_time) do
    if state.flow_control.enabled do
      # Remove old timestamps outside the window
      window_start = current_time - state.flow_control.window_size_ms
      recent_timestamps = Enum.filter(state.flow_control.chunk_timestamps, &(&1 >= window_start))

      # Check if we're exceeding the rate limit
      if length(recent_timestamps) >= state.flow_control.max_chunks_per_second do
        # Calculate delay needed
        oldest_in_window = Enum.min(recent_timestamps, fn -> current_time end)
        delay_needed = state.flow_control.window_size_ms - (current_time - oldest_in_window)

        if delay_needed > 0 do
          updated_flow_control = %{state.flow_control |
            chunk_timestamps: recent_timestamps,
            backpressure_active: true
          }
          {:delay, delay_needed, updated_flow_control}
        else
          {:error, :rate_limit_exceeded}
        end
      else
        # Rate is acceptable
        updated_timestamps = [current_time | recent_timestamps]
        updated_flow_control = %{state.flow_control |
          chunk_timestamps: updated_timestamps,
          backpressure_active: false
        }
        {:ok, updated_flow_control}
      end
    else
      {:ok, state.flow_control}
    end
  end

  # Process chunk with intelligent ordering
  defp process_chunk_with_ordering(chunk_data, sequence_number, state, updated_flow_control, current_time) do
    case sequence_number do
      nil ->
        # No sequence number - process immediately
        process_unsequenced_chunk(chunk_data, state, updated_flow_control, current_time)

      seq_num ->
        # Sequence number provided - handle ordering
        process_sequenced_chunk(chunk_data, seq_num, state, updated_flow_control, current_time)
    end
  end

  # Process chunk without sequence ordering
  defp process_unsequenced_chunk(chunk_data, state, updated_flow_control, current_time) do
    # Update validation state
    updated_validation = %{state.validation |
      current_total_size: state.validation.current_total_size + byte_size(chunk_data)
    }

    # Add to aggregation buffer
    {processed_chunks, updated_aggregation} = aggregate_chunk(chunk_data, state.aggregation, current_time)

    updated_state = %{state |
      sequence_counter: state.sequence_counter + 1,
      flow_control: updated_flow_control,
      validation: updated_validation,
      aggregation: updated_aggregation
    }

    {:ok, processed_chunks, updated_state}
  end

  # Process chunk with sequence ordering
  defp process_sequenced_chunk(chunk_data, sequence_number, state, updated_flow_control, current_time) do
    expected_sequence = state.sequence_counter

    if sequence_number == expected_sequence do
      # This is the next expected chunk - process it and any subsequent pending chunks
      process_in_order_chunks(chunk_data, sequence_number, state, updated_flow_control, current_time)
    else
      # Out of order chunk - store for later processing
      store_pending_chunk(chunk_data, sequence_number, state, updated_flow_control)
    end
  end

  # Process chunks in correct order
  defp process_in_order_chunks(chunk_data, sequence_number, state, updated_flow_control, current_time) do
    # Process current chunk
    updated_validation = %{state.validation |
      current_total_size: state.validation.current_total_size + byte_size(chunk_data)
    }

    {initial_chunks, updated_aggregation} = aggregate_chunk(chunk_data, state.aggregation, current_time)

    # Process any subsequent pending chunks in order
    {all_processed_chunks, final_aggregation, final_validation, final_sequence, updated_pending} =
      process_pending_chunks_in_order(
        initial_chunks,
        updated_aggregation,
        updated_validation,
        sequence_number + 1,
        state.pending_chunks,
        current_time
      )

    updated_state = %{state |
      sequence_counter: final_sequence,
      pending_chunks: updated_pending,
      flow_control: updated_flow_control,
      validation: final_validation,
      aggregation: final_aggregation
    }

    {:ok, all_processed_chunks, updated_state}
  end

  # Store out-of-order chunk for later processing
  defp store_pending_chunk(chunk_data, sequence_number, state, updated_flow_control) do
    if map_size(state.pending_chunks) >= state.max_pending_chunks do
      Logger.warning("Too many pending chunks for session #{state.session_id}, dropping chunk #{sequence_number}")
      updated_state = %{state | flow_control: updated_flow_control}
      {:ok, [], updated_state}
    else
      updated_pending = Map.put(state.pending_chunks, sequence_number, chunk_data)
      updated_state = %{state | pending_chunks: updated_pending, flow_control: updated_flow_control}
      {:ok, [], updated_state}
    end
  end

  # Process pending chunks in sequential order
  defp process_pending_chunks_in_order(processed_chunks, aggregation, validation, next_sequence, pending_chunks, current_time) do
    case Map.get(pending_chunks, next_sequence) do
      nil ->
        # No more consecutive chunks available
        {processed_chunks, aggregation, validation, next_sequence, pending_chunks}

      chunk_data ->
        # Found the next chunk in sequence
        updated_validation = %{validation |
          current_total_size: validation.current_total_size + byte_size(chunk_data)
        }

        {new_chunks, updated_aggregation} = aggregate_chunk(chunk_data, aggregation, current_time)
        all_chunks = processed_chunks ++ new_chunks
        updated_pending = Map.delete(pending_chunks, next_sequence)

        # Continue processing the next sequence number
        process_pending_chunks_in_order(
          all_chunks,
          updated_aggregation,
          updated_validation,
          next_sequence + 1,
          updated_pending,
          current_time
        )
    end
  end

  # Aggregate chunk into buffer and determine if flush is needed
  defp aggregate_chunk(chunk_data, aggregation, current_time) do
    new_buffer = aggregation.buffer <> chunk_data
    new_buffer_size = aggregation.buffer_size + byte_size(chunk_data)

    updated_aggregation = %{aggregation |
      buffer: new_buffer,
      buffer_size: new_buffer_size
    }

    # Check if we should flush
    should_flush = new_buffer_size >= aggregation.flush_threshold or
                   (current_time - aggregation.last_flush_time) >= aggregation.flush_interval_ms

    if should_flush do
      # Flush the buffer
      final_aggregation = %{updated_aggregation |
        buffer: "",
        buffer_size: 0,
        last_flush_time: current_time
      }
      {[new_buffer], final_aggregation}
    else
      # Keep buffering
      {[], updated_aggregation}
    end
  end

  # Calculate chunks per second for metrics
  defp calculate_chunks_per_second(state, current_time) do
    if length(state.flow_control.chunk_timestamps) > 0 do
      window_start = current_time - state.flow_control.window_size_ms
      recent_chunks = Enum.count(state.flow_control.chunk_timestamps, &(&1 >= window_start))
      recent_chunks / (state.flow_control.window_size_ms / 1000)
    else
      0.0
    end
  end
end
