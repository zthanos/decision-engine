defmodule DecisionEngine.SSEFormatter do
  @moduledoc """
  Utilities for formatting and delivering Server-Sent Events (SSE).
  
  This module provides functions for:
  - Formatting data as SSE-compliant event strings
  - Validating SSE event structures
  - Handling different event types with appropriate formatting
  - Managing SSE connection headers and responses
  """
  
  @typedoc """
  SSE event structure for consistent formatting.
  """
  @type sse_event :: %{
    event: String.t(),
    data: map(),
    id: String.t() | nil,
    retry: non_neg_integer() | nil
  }
  
  @doc """
  Formats an SSE event for transmission to the client.
  
  ## Parameters
  - event_type: The type of event (e.g., "content_chunk", "processing_complete")
  - data: The data payload to send (will be JSON encoded)
  - opts: Optional parameters (id, retry)
  
  ## Returns
  - Formatted SSE string ready for transmission
  
  ## Examples
      iex> DecisionEngine.SSEFormatter.format_event("message", %{content: "Hello"})
      "event: message\\ndata: {\\"content\\":\\"Hello\\"}\\n\\n"
  """
  @spec format_event(String.t(), map(), keyword()) :: String.t()
  def format_event(event_type, data, opts \\ []) do
    id = Keyword.get(opts, :id)
    retry = Keyword.get(opts, :retry)
    
    event_parts = []
    
    # Add event type
    event_parts = ["event: #{event_type}" | event_parts]
    
    # Add ID if provided
    event_parts = if id, do: ["id: #{id}" | event_parts], else: event_parts
    
    # Add retry if provided
    event_parts = if retry, do: ["retry: #{retry}" | event_parts], else: event_parts
    
    # Add data (JSON encoded)
    json_data = Jason.encode!(data)
    event_parts = ["data: #{json_data}" | event_parts]
    
    # Reverse to get correct order and join with newlines
    event_parts
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Kernel.<>("\n\n")  # SSE events end with double newline
  end
  
  @doc """
  Formats multiple data lines for a single SSE event.
  
  Useful for sending large payloads that need to be split across multiple data lines.
  
  ## Parameters
  - event_type: The type of event
  - data_lines: List of strings, each will be a separate data line
  - opts: Optional parameters (id, retry)
  
  ## Returns
  - Formatted SSE string with multiple data lines
  """
  @spec format_multiline_event(String.t(), [String.t()], keyword()) :: String.t()
  def format_multiline_event(event_type, data_lines, opts \\ []) do
    id = Keyword.get(opts, :id)
    retry = Keyword.get(opts, :retry)
    
    event_parts = []
    
    # Add event type
    event_parts = ["event: #{event_type}" | event_parts]
    
    # Add ID if provided
    event_parts = if id, do: ["id: #{id}" | event_parts], else: event_parts
    
    # Add retry if provided
    event_parts = if retry, do: ["retry: #{retry}" | event_parts], else: event_parts
    
    # Reverse the header parts to get correct order
    header_parts = Enum.reverse(event_parts)
    
    # Add each data line in original order
    data_parts = Enum.map(data_lines, &("data: #{&1}"))
    
    # Combine header and data parts
    (header_parts ++ data_parts)
    |> Enum.join("\n")
    |> Kernel.<>("\n\n")
  end
  
  @doc """
  Creates a keep-alive (heartbeat) SSE event.
  
  Sends a comment line to keep the SSE connection alive without triggering
  client-side event handlers.
  
  ## Returns
  - SSE comment string for keep-alive
  """
  @spec format_keepalive() :: String.t()
  def format_keepalive do
    ": keepalive\n\n"
  end
  
  @doc """
  Validates an SSE event structure.
  
  ## Parameters
  - event: The event structure to validate
  
  ## Returns
  - :ok if valid
  - {:error, reason} if invalid
  """
  @spec validate_event(map()) :: :ok | {:error, String.t()}
  def validate_event(%{event: event_type, data: data}) when is_binary(event_type) and is_map(data) do
    :ok
  end
  def validate_event(%{event: event_type}) when not is_binary(event_type) do
    {:error, "Event type must be a string"}
  end
  def validate_event(%{data: data}) when not is_map(data) do
    {:error, "Event data must be a map"}
  end
  def validate_event(_) do
    {:error, "Event must have 'event' and 'data' fields"}
  end
  
  @doc """
  Sets the appropriate headers for SSE responses.
  
  ## Parameters
  - conn: The Plug.Conn struct
  
  ## Returns
  - Updated conn with SSE headers set
  """
  @spec set_sse_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def set_sse_headers(conn) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
    |> Plug.Conn.put_resp_header("cache-control", "no-cache")
    |> Plug.Conn.put_resp_header("connection", "keep-alive")
    |> Plug.Conn.put_resp_header("access-control-allow-origin", "*")
    |> Plug.Conn.put_resp_header("access-control-allow-headers", "Cache-Control")
  end
  
  @doc """
  Sends an SSE event through a chunked connection.
  
  ## Parameters
  - conn: The chunked connection
  - event_type: Type of the event
  - data: Event data
  - opts: Optional parameters
  
  ## Returns
  - {:ok, conn} if successful
  - {:error, reason} if failed
  """
  @spec send_event(Plug.Conn.t(), String.t(), map(), keyword()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send_event(conn, event_type, data, opts \\ []) do
    event_string = format_event(event_type, data, opts)
    Plug.Conn.chunk(conn, event_string)
  end
  
  @doc """
  Sends a keep-alive event through a chunked connection.
  
  ## Parameters
  - conn: The chunked connection
  
  ## Returns
  - {:ok, conn} if successful
  - {:error, reason} if failed
  """
  @spec send_keepalive(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def send_keepalive(conn) do
    keepalive_string = format_keepalive()
    Plug.Conn.chunk(conn, keepalive_string)
  end
  
  @doc """
  Creates standard error event data.
  
  ## Parameters
  - reason: The error reason (atom or string)
  - context: Optional context information
  
  ## Returns
  - Map suitable for SSE error event data
  """
  @spec create_error_data(term(), map()) :: map()
  def create_error_data(reason, context \\ %{}) do
    base_data = %{
      error: true,
      reason: to_string(reason),
      timestamp: DateTime.utc_now()
    }
    
    Map.merge(base_data, context)
  end
  
  @doc """
  Creates standard success event data.
  
  ## Parameters
  - message: Success message
  - context: Optional context information
  
  ## Returns
  - Map suitable for SSE success event data
  """
  @spec create_success_data(String.t(), map()) :: map()
  def create_success_data(message, context \\ %{}) do
    base_data = %{
      success: true,
      message: message,
      timestamp: DateTime.utc_now()
    }
    
    Map.merge(base_data, context)
  end
end