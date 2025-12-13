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
    status: :initializing | :streaming | :completed | :error | :timeout,
    start_time: DateTime.t(),
    timeout_ref: reference() | nil
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
      status: :initializing,
      start_time: DateTime.utc_now(),
      timeout_ref: timeout_ref
    }

    Logger.info("StreamManager started for session #{session_id}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:start_streaming, signals, decision_result, config, domain}, state) do
    Logger.info("Starting streaming for session #{state.session_id}, domain: #{domain}")

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
  def handle_info({:chunk, content}, state) do
    # Check content size limits
    new_content = state.accumulated_content <> content

    if byte_size(new_content) > @max_content_size do
      Logger.warning("Content size limit exceeded for session #{state.session_id}")
      send_sse_event(state.sse_pid, "error", %{
        reason: "content_size_limit_exceeded",
        session_id: state.session_id
      })
      {:stop, :normal, %{state | status: :error}}
    else
      # Render accumulated markdown progressively
      case MarkdownRenderer.render_to_html(new_content) do
        {:ok, rendered_html} ->
          # Send chunk to SSE client
          send_sse_event(state.sse_pid, "content_chunk", %{
            content: content,
            rendered_html: rendered_html,
            accumulated_content: new_content,
            session_id: state.session_id,
            timestamp: DateTime.utc_now()
          })

          {:noreply, %{state | accumulated_content: new_content}}

        {:error, _reason} ->
          # Fallback to raw content if markdown rendering fails
          send_sse_event(state.sse_pid, "content_chunk", %{
            content: content,
            rendered_html: Phoenix.HTML.html_escape(new_content) |> Phoenix.HTML.safe_to_string(),
            accumulated_content: new_content,
            session_id: state.session_id,
            timestamp: DateTime.utc_now()
          })

          {:noreply, %{state | accumulated_content: new_content}}
      end
    end
  end

  @impl true
  def handle_info({:complete}, state) do
    Logger.info("Stream completed for session #{state.session_id}")

    # Final markdown rendering
    final_html = MarkdownRenderer.render_to_html!(state.accumulated_content)

    # Send completion event
    send_sse_event(state.sse_pid, "processing_complete", %{
      final_content: state.accumulated_content,
      final_html: final_html,
      session_id: state.session_id,
      timestamp: DateTime.utc_now(),
      duration_ms: DateTime.diff(DateTime.utc_now(), state.start_time, :millisecond)
    })

    {:stop, :normal, %{state | status: :completed}}
  end

  @impl true
  def handle_info({:error, reason}, state) do
    Logger.error("Stream error for session #{state.session_id}: #{inspect(reason)}")

    send_sse_event(state.sse_pid, "processing_error", %{
      reason: reason,
      session_id: state.session_id,
      timestamp: DateTime.utc_now()
    })

    {:stop, :normal, %{state | status: :error}}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("Stream timeout for session #{state.session_id}")

    send_sse_event(state.sse_pid, "stream_timeout", %{
      session_id: state.session_id,
      timestamp: DateTime.utc_now(),
      partial_content: state.accumulated_content
    })

    {:stop, :normal, %{state | status: :timeout}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.info("SSE connection closed for session #{state.session_id}: #{inspect(reason)}")
    {:stop, :normal, state}
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
end
