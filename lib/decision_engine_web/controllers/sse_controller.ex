defmodule DecisionEngineWeb.SSEController do
  use DecisionEngineWeb, :controller
  
  require Logger
  
  @moduledoc """
  Handles Server-Sent Events (SSE) connections for streaming LLM responses.
  Provides real-time content delivery with proper connection management.
  """
  
  @timeout 30_000  # 30 seconds
  
  def stream(conn, %{"session_id" => session_id}) do
    Logger.info("Starting SSE stream for session: #{session_id}")
    
    conn = 
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-headers", "Cache-Control")
      |> send_chunked(200)
    
    # Start stream manager for this session
    case start_stream_manager(session_id) do
      {:ok, _pid} ->
        # Send initial connection event
        case send_sse_event(conn, "connection_established", %{session_id: session_id}) do
          {:ok, conn} -> 
            # Start heartbeat to keep connection alive
            schedule_heartbeat(session_id)
            handle_sse_loop(conn, session_id)
          {:error, reason} -> 
            Logger.error("Failed to send initial SSE event: #{inspect(reason)}")
            conn
        end
      
      {:error, reason} ->
        Logger.error("Failed to start StreamManager for session #{session_id}: #{inspect(reason)}")
        # Send error and close connection
        case send_sse_event(conn, "connection_error", %{reason: "Failed to initialize stream", session_id: session_id}) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    end
  end
  
  def stream(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "session_id parameter is required"})
  end
  
  defp start_stream_manager(session_id) do
    # Start the actual StreamManager for this session
    case DecisionEngine.StreamManager.start_link(session_id, self()) do
      {:ok, pid} -> 
        Logger.info("StreamManager started for session #{session_id}")
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        Logger.info("StreamManager already exists for session #{session_id}")
        {:ok, pid}
      {:error, reason} ->
        Logger.error("Failed to start StreamManager for session #{session_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  defp handle_sse_loop(conn, session_id) do
    receive do
      {:sse_event, event_type, data} ->
        case send_sse_event(conn, event_type, data) do
          {:ok, conn} -> handle_sse_loop(conn, session_id)
          {:error, :closed} ->
            Logger.info("SSE connection closed by client for session #{session_id}")
            cleanup_connection(session_id)
            conn
          {:error, reason} -> 
            Logger.error("Failed to send SSE event for session #{session_id}: #{inspect(reason)}")
            cleanup_connection(session_id)
            conn
        end
      
      {:heartbeat, ^session_id} ->
        # Send heartbeat and schedule next one
        case send_sse_event(conn, "heartbeat", %{timestamp: DateTime.utc_now()}) do
          {:ok, conn} -> 
            schedule_heartbeat(session_id)
            handle_sse_loop(conn, session_id)
          {:error, reason} ->
            Logger.info("Heartbeat failed for session #{session_id}: #{inspect(reason)}")
            cleanup_connection(session_id)
            conn
        end

      {:EXIT, _pid, reason} ->
        Logger.info("Stream process exited for session #{session_id}: #{inspect(reason)}")
        case send_sse_event(conn, "connection_closed", %{reason: "Stream ended"}) do
          {:ok, conn} -> 
            cleanup_connection(session_id)
            conn
          {:error, _} -> 
            cleanup_connection(session_id)
            conn
        end
        
    after
      @timeout ->
        Logger.info("SSE connection timeout for session #{session_id}")
        case send_sse_event(conn, "timeout", %{message: "Connection timeout"}) do
          {:ok, conn} -> 
            cleanup_connection(session_id)
            conn
          {:error, _} -> 
            cleanup_connection(session_id)
            conn
        end
    end
  end
  
  defp send_sse_event(conn, event_type, data) do
    try do
      json_data = Jason.encode!(data)
      sse_data = format_sse_event(event_type, json_data)
      
      case chunk(conn, sse_data) do
        {:ok, conn} -> {:ok, conn}
        {:error, reason} -> {:error, reason}
      end
    rescue
      error ->
        Logger.error("Error encoding SSE data: #{inspect(error)}")
        {:error, error}
    end
  end
  
  defp format_sse_event(event_type, data) do
    "event: #{event_type}\ndata: #{data}\n\n"
  end
  
  defp schedule_heartbeat(session_id) do
    # Send heartbeat every 10 seconds to keep connection alive
    Process.send_after(self(), {:heartbeat, session_id}, 10_000)
  end

  defp cleanup_connection(session_id) do
    Logger.info("Cleaning up SSE connection for session: #{session_id}")
    
    # Cancel the StreamManager if it exists
    case DecisionEngine.StreamManager.cancel_stream(session_id) do
      :ok -> Logger.debug("StreamManager cancelled for session #{session_id}")
      {:error, :not_found} -> Logger.debug("No StreamManager found to cancel for session #{session_id}")
    end
    
    :ok
  end
end