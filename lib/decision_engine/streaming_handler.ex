# lib/decision_engine/streaming_handler.ex
defmodule DecisionEngine.StreamingHandler do
  @moduledoc """
  Manages real-time streaming of LLM responses with comprehensive lifecycle handling.

  This module provides a unified interface for streaming LLM responses across all AI features
  in the application. It handles connection establishment, status management, error recovery,
  and visual indicators for streaming operations.

  ## Features
  - Real-time streaming connection management
  - Visual status indicators for streaming progress
  - Error handling and retry mechanisms
  - Connection lifecycle management
  - Integration with existing StreamManager and SSE infrastructure
  - Unified streaming interface for all AI features

  ## Usage
      # Start a new streaming session
      {:ok, stream_ref} = StreamingHandler.start_stream(session_id, config, self())

      # Handle streaming chunks
      StreamingHandler.handle_chunk(chunk_data, stream_ref)

      # Stop streaming
      StreamingHandler.stop_stream(stream_ref)

      # Check streaming status
      status = StreamingHandler.stream_status(stream_ref)
  """

  use GenServer
  require Logger

  alias DecisionEngine.StreamManager

  @typedoc """
  Streaming session reference for tracking active streams.
  """
  @type stream_ref :: reference()

  @typedoc """
  Streaming status indicators.
  """
  @type stream_status :: :connecting | :active | :complete | :error | :timeout

  @typedoc """
  Streaming configuration options.
  """
  @type stream_config :: %{
    session_id: String.t(),
    llm_config: map(),
    callback_pid: pid(),
    timeout: non_neg_integer(),
    retry_attempts: non_neg_integer(),
    visual_indicators: boolean()
  }

  @typedoc """
  Stream state for internal tracking.
  """
  @type stream_state :: %{
    stream_ref: stream_ref(),
    session_id: String.t(),
    status: stream_status(),
    config: stream_config(),
    start_time: DateTime.t(),
    last_activity: DateTime.t(),
    retry_count: non_neg_integer(),
    accumulated_content: String.t(),
    error_reason: term() | nil
  }

  # Default configuration values
  @default_timeout 90_000  # 90 seconds
  @default_retry_attempts 3
  @heartbeat_interval 5_000  # 5 seconds
  @max_content_size 1_048_576  # 1MB

  ## Public API

  @doc """
  Starts a new streaming session for LLM responses.

  ## Parameters
  - session_id: Unique identifier for the streaming session
  - config: LLM configuration map with provider, model, etc.
  - callback_pid: Process to receive streaming events

  ## Returns
  - {:ok, stream_ref} on successful start
  - {:error, reason} if streaming fails to start

  ## Events sent to callback_pid
  - {:stream_status, stream_ref, :connecting} - Connection being established
  - {:stream_status, stream_ref, :active} - Streaming is active
  - {:stream_chunk, stream_ref, content} - New content chunk received
  - {:stream_status, stream_ref, :complete} - Streaming completed successfully
  - {:stream_status, stream_ref, :error, reason} - Streaming failed
  """
  @spec start_stream(String.t(), map(), pid()) :: {:ok, stream_ref()} | {:error, term()}
  def start_stream(session_id, config, callback_pid) do
    GenServer.call(__MODULE__, {:start_stream, session_id, config, callback_pid})
  end

  @doc """
  Handles incoming content chunks from LLM streaming.

  This function is called by the LLM client when new content chunks are received.
  It processes the chunks and forwards them to the appropriate callback process.

  ## Parameters
  - chunk_data: Binary content chunk from LLM
  - stream_ref: Reference to the streaming session

  ## Returns
  - :ok if chunk processed successfully
  - {:error, reason} if processing fails
  """
  @spec handle_chunk(binary(), stream_ref()) :: :ok | {:error, term()}
  def handle_chunk(chunk_data, stream_ref) do
    GenServer.cast(__MODULE__, {:handle_chunk, chunk_data, stream_ref})
  end

  @doc """
  Stops an active streaming session.

  ## Parameters
  - stream_ref: Reference to the streaming session to stop

  ## Returns
  - :ok if stream stopped successfully
  - {:error, :not_found} if stream reference not found
  """
  @spec stop_stream(stream_ref()) :: :ok | {:error, :not_found}
  def stop_stream(stream_ref) do
    GenServer.call(__MODULE__, {:stop_stream, stream_ref})
  end

  @doc """
  Gets the current status of a streaming session.

  ## Parameters
  - stream_ref: Reference to the streaming session

  ## Returns
  - stream_status() if session exists
  - {:error, :not_found} if session not found
  """
  @spec stream_status(stream_ref()) :: stream_status() | {:error, :not_found}
  def stream_status(stream_ref) do
    GenServer.call(__MODULE__, {:stream_status, stream_ref})
  end

  @doc """
  Lists all active streaming sessions.

  ## Returns
  - List of {stream_ref, session_id, status} tuples for active streams
  """
  @spec list_active_streams() :: [{stream_ref(), String.t(), stream_status()}]
  def list_active_streams() do
    GenServer.call(__MODULE__, :list_active_streams)
  end

  @doc """
  Starts the StreamingHandler GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize state with empty streams tracking
    state = %{
      streams: %{},  # stream_ref -> stream_state
      session_to_ref: %{}  # session_id -> stream_ref
    }

    Logger.info("StreamingHandler started")
    {:ok, state}
  end

  @impl true
  def handle_call({:start_stream, session_id, config, callback_pid}, _from, state) do
    Logger.info("Starting streaming session: #{session_id}")

    # Generate unique stream reference
    stream_ref = make_ref()

    # Validate LLM configuration
    case validate_streaming_config(config) do
      :ok ->
        # Create stream configuration
        stream_config = %{
          session_id: session_id,
          llm_config: config,
          callback_pid: callback_pid,
          timeout: Map.get(config, :timeout, @default_timeout),
          retry_attempts: Map.get(config, :retry_attempts, @default_retry_attempts),
          visual_indicators: Map.get(config, :visual_indicators, true)
        }

        # Initialize stream state
        stream_state = %{
          stream_ref: stream_ref,
          session_id: session_id,
          status: :connecting,
          config: stream_config,
          start_time: DateTime.utc_now(),
          last_activity: DateTime.utc_now(),
          retry_count: 0,
          accumulated_content: "",
          error_reason: nil
        }

        # Update state
        new_state = %{state |
          streams: Map.put(state.streams, stream_ref, stream_state),
          session_to_ref: Map.put(state.session_to_ref, session_id, stream_ref)
        }

        # Send initial status
        send_stream_event(callback_pid, :stream_status, stream_ref, :connecting)

        # Start connection establishment
        schedule_connection_establishment(stream_ref)

        {:reply, {:ok, stream_ref}, new_state}

      {:error, reason} ->
        Logger.error("Invalid streaming configuration for session #{session_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:stop_stream, stream_ref}, _from, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      stream_state ->
        Logger.info("Stopping streaming session: #{stream_state.session_id}")

        # Send completion status
        send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :complete)

        # Clean up state
        new_state = %{state |
          streams: Map.delete(state.streams, stream_ref),
          session_to_ref: Map.delete(state.session_to_ref, stream_state.session_id)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:stream_status, stream_ref}, _from, state) do
    case Map.get(state.streams, stream_ref) do
      nil -> {:reply, {:error, :not_found}, state}
      stream_state -> {:reply, stream_state.status, state}
    end
  end

  @impl true
  def handle_call(:list_active_streams, _from, state) do
    active_streams = state.streams
    |> Enum.map(fn {stream_ref, stream_state} ->
      {stream_ref, stream_state.session_id, stream_state.status}
    end)

    {:reply, active_streams, state}
  end

  @impl true
  def handle_cast({:handle_chunk, chunk_data, stream_ref}, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        Logger.warning("Received chunk for unknown stream: #{inspect(stream_ref)}")
        {:noreply, state}

      stream_state ->
        # Update accumulated content
        new_content = stream_state.accumulated_content <> chunk_data

        # Check content size limits
        if byte_size(new_content) > @max_content_size do
          Logger.warning("Content size limit exceeded for session #{stream_state.session_id}")
          handle_stream_error(stream_ref, :content_size_limit_exceeded, state)
        else
          # Update stream state
          updated_stream_state = %{stream_state |
            accumulated_content: new_content,
            last_activity: DateTime.utc_now(),
            status: :active
          }

          new_state = %{state |
            streams: Map.put(state.streams, stream_ref, updated_stream_state)
          }

          # Send chunk to callback
          send_stream_event(stream_state.config.callback_pid, :stream_chunk, stream_ref, chunk_data)

          # Send status update if this is the first chunk
          if stream_state.status == :connecting do
            send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :active)
          end

          {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info({:establish_connection, stream_ref}, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        Logger.warning("Connection establishment for unknown stream: #{inspect(stream_ref)}")
        {:noreply, state}

      stream_state ->
        Logger.debug("Establishing streaming connection for session: #{stream_state.session_id}")

        # Start StreamManager for this session
        case start_stream_manager(stream_state) do
          :ok ->
            # Connection established successfully
            updated_stream_state = %{stream_state |
              status: :active,
              last_activity: DateTime.utc_now()
            }

            new_state = %{state |
              streams: Map.put(state.streams, stream_ref, updated_stream_state)
            }

            # Send status update
            send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :active)

            # Schedule heartbeat
            schedule_heartbeat(stream_ref)

            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("Failed to establish streaming connection for session #{stream_state.session_id}: #{inspect(reason)}")
            handle_stream_error(stream_ref, reason, state)
        end
    end
  end

  @impl true
  def handle_info({:heartbeat, stream_ref}, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        # Stream no longer exists, ignore heartbeat
        {:noreply, state}

      stream_state ->
        # Check if stream is still active
        time_since_activity = DateTime.diff(DateTime.utc_now(), stream_state.last_activity, :millisecond)

        if time_since_activity > stream_state.config.timeout do
          Logger.warning("Stream timeout for session #{stream_state.session_id}")
          handle_stream_error(stream_ref, :timeout, state)
        else
          # Schedule next heartbeat
          schedule_heartbeat(stream_ref)
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:stream_complete, stream_ref}, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        {:noreply, state}

      stream_state ->
        Logger.info("Stream completed for session: #{stream_state.session_id}")

        # Update status
        updated_stream_state = %{stream_state | status: :complete}

        new_state = %{state |
          streams: Map.put(state.streams, stream_ref, updated_stream_state)
        }

        # Send completion event
        send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :complete)

        # Clean up after a delay to allow final processing
        Process.send_after(self(), {:cleanup_stream, stream_ref}, 1000)

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:cleanup_stream, stream_ref}, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        {:noreply, state}

      stream_state ->
        Logger.debug("Cleaning up stream for session: #{stream_state.session_id}")

        new_state = %{state |
          streams: Map.delete(state.streams, stream_ref),
          session_to_ref: Map.delete(state.session_to_ref, stream_state.session_id)
        }

        {:noreply, new_state}
    end
  end

  ## Private Functions

  defp validate_streaming_config(config) do
    required_fields = [:provider, :model, :api_key]

    missing_fields = required_fields
    |> Enum.filter(fn field ->
      value = Map.get(config, field) || Map.get(config, Atom.to_string(field))
      is_nil(value) or (is_binary(value) and String.trim(value) == "")
    end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp start_stream_manager(stream_state) do
    session_id = stream_state.session_id

    # Check if StreamManager already exists
    case StreamManager.get_stream_status(session_id) do
      {:error, :not_found} ->
        # Start new StreamManager - it will handle SSE connection internally
        case StreamManager.start_link(session_id, self()) do
          {:ok, _pid} ->
            Logger.debug("StreamManager started for session #{session_id}")
            :ok

          {:error, {:already_started, _pid}} ->
            Logger.debug("StreamManager already exists for session #{session_id}")
            :ok

          {:error, reason} ->
            Logger.error("Failed to start StreamManager for session #{session_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, _status} ->
        # StreamManager already exists
        Logger.debug("StreamManager already exists for session #{session_id}")
        :ok
    end
  end

  defp handle_stream_error(stream_ref, reason, state) do
    case Map.get(state.streams, stream_ref) do
      nil ->
        {:noreply, state}

      stream_state ->
        Logger.error("Stream error for session #{stream_state.session_id}: #{inspect(reason)}")

        # Check if we should retry
        if stream_state.retry_count < stream_state.config.retry_attempts and reason != :content_size_limit_exceeded do
          # Attempt retry
          updated_stream_state = %{stream_state |
            retry_count: stream_state.retry_count + 1,
            status: :connecting,
            last_activity: DateTime.utc_now()
          }

          new_state = %{state |
            streams: Map.put(state.streams, stream_ref, updated_stream_state)
          }

          Logger.info("Retrying stream for session #{stream_state.session_id} (attempt #{updated_stream_state.retry_count})")

          # Send retry status
          send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :connecting)

          # Schedule retry
          Process.send_after(self(), {:establish_connection, stream_ref}, 1000)

          {:noreply, new_state}
        else
          # Max retries reached or non-retryable error
          updated_stream_state = %{stream_state |
            status: :error,
            error_reason: reason
          }

          new_state = %{state |
            streams: Map.put(state.streams, stream_ref, updated_stream_state)
          }

          # Send error event
          send_stream_event(stream_state.config.callback_pid, :stream_status, stream_ref, :error, reason)

          # Schedule cleanup
          Process.send_after(self(), {:cleanup_stream, stream_ref}, 5000)

          {:noreply, new_state}
        end
    end
  end

  defp send_stream_event(callback_pid, event_type, stream_ref, status, extra \\ nil) do
    event = case {event_type, extra} do
      {:stream_status, nil} -> {event_type, stream_ref, status}
      {:stream_status, reason} -> {event_type, stream_ref, status, reason}
      {:stream_chunk, nil} -> {event_type, stream_ref, status}
      _ -> {event_type, stream_ref, status, extra}
    end

    send(callback_pid, event)
  end

  defp schedule_connection_establishment(stream_ref) do
    Process.send_after(self(), {:establish_connection, stream_ref}, 100)
  end

  defp schedule_heartbeat(stream_ref) do
    Process.send_after(self(), {:heartbeat, stream_ref}, @heartbeat_interval)
  end
end
