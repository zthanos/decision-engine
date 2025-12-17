# lib/decision_engine/req_llm_correlation.ex
defmodule DecisionEngine.ReqLLMCorrelation do
  @moduledoc """
  Correlation ID tracking system for ReqLLM integration.

  This module provides request correlation ID generation and tracking, correlation ID
  propagation across system components, and correlation-based request tracing and
  debugging capabilities. It enables end-to-end request tracking across the entire
  system for better observability and debugging.
  """

  require Logger

  @correlation_store :req_llm_correlation_ets
  @correlation_header "x-correlation-id"
  @default_ttl 24 * 60 * 60 * 1000  # 24 hours in milliseconds

  @doc """
  Initializes the correlation tracking system.

  ## Returns
  - :ok on successful initialization
  """
  @spec init() :: :ok
  def init do
    # Create ETS table for storing correlation data if it doesn't exist
    case :ets.whereis(@correlation_store) do
      :undefined ->
        :ets.new(@correlation_store, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    Logger.info("ReqLLM Correlation tracking system initialized")
    :ok
  end

  @doc """
  Generates a new correlation ID for request tracking.

  ## Parameters
  - prefix: Optional prefix for the correlation ID (default: "req")

  ## Returns
  - String correlation ID
  """
  @spec generate_correlation_id(String.t()) :: String.t()
  def generate_correlation_id(prefix \\ "req") do
    timestamp = System.system_time(:millisecond)
    random_part = :crypto.strong_rand_bytes(8) |> Base.encode64(padding: false)
    node_hash = :erlang.phash2(Node.self(), 1000)

    "#{prefix}-#{timestamp}-#{node_hash}-#{random_part}"
  end

  @doc """
  Starts tracking a correlation ID with associated context.

  ## Parameters
  - correlation_id: The correlation ID to track
  - context: Initial context map containing request details
  - ttl_ms: Time-to-live in milliseconds (optional, defaults to 24 hours)

  ## Returns
  - :ok on success
  """
  @spec start_tracking(String.t(), map(), integer()) :: :ok
  def start_tracking(correlation_id, context, ttl_ms \\ @default_ttl) do
    timestamp = System.system_time(:millisecond)

    correlation_data = %{
      correlation_id: correlation_id,
      created_at: timestamp,
      ttl: timestamp + ttl_ms,
      initial_context: context,
      trace_events: [],
      components: MapSet.new(),
      status: :active,
      metadata: %{}
    }

    :ets.insert(@correlation_store, {correlation_id, correlation_data})

    # Log correlation start
    Logger.info("Started correlation tracking", %{
      event: "reqllm_correlation_start",
      correlation_id: correlation_id,
      context: sanitize_context_for_logging(context),
      timestamp: timestamp
    })

    :ok
  end

  @doc """
  Adds a trace event to an existing correlation.

  ## Parameters
  - correlation_id: The correlation ID to add the event to
  - component: Component name that generated the event
  - event_type: Type of event (:request, :response, :error, :retry, etc.)
  - event_data: Event-specific data
  - metadata: Additional metadata (optional)

  ## Returns
  - :ok on success
  - {:error, :not_found} if correlation ID doesn't exist
  """
  @spec add_trace_event(String.t(), atom(), atom(), term(), map()) :: :ok | {:error, :not_found}
  def add_trace_event(correlation_id, component, event_type, event_data, metadata \\ %{}) do
    case :ets.lookup(@correlation_store, correlation_id) do
      [{^correlation_id, correlation_data}] ->
        timestamp = System.system_time(:millisecond)

        trace_event = %{
          timestamp: timestamp,
          component: component,
          event_type: event_type,
          event_data: sanitize_event_data(event_data),
          metadata: metadata,
          sequence: length(correlation_data.trace_events) + 1
        }

        updated_data = correlation_data
        |> Map.update(:trace_events, [trace_event], fn events -> events ++ [trace_event] end)
        |> Map.update(:components, MapSet.new([component]), fn components ->
          MapSet.put(components, component)
        end)
        |> Map.put(:last_activity, timestamp)

        :ets.insert(@correlation_store, {correlation_id, updated_data})

        # Log trace event
        Logger.debug("Correlation trace event added", %{
          event: "reqllm_correlation_trace",
          correlation_id: correlation_id,
          component: component,
          event_type: event_type,
          sequence: trace_event.sequence,
          timestamp: timestamp
        })

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates the status of a correlation.

  ## Parameters
  - correlation_id: The correlation ID to update
  - status: New status (:active, :completed, :failed, :timeout)
  - final_data: Final data to associate with the correlation (optional)

  ## Returns
  - :ok on success
  - {:error, :not_found} if correlation ID doesn't exist
  """
  @spec update_status(String.t(), atom(), term()) :: :ok | {:error, :not_found}
  def update_status(correlation_id, status, final_data \\ nil) do
    case :ets.lookup(@correlation_store, correlation_id) do
      [{^correlation_id, correlation_data}] ->
        timestamp = System.system_time(:millisecond)

        updated_data = correlation_data
        |> Map.put(:status, status)
        |> Map.put(:completed_at, timestamp)
        |> Map.put(:duration_ms, timestamp - correlation_data.created_at)

        updated_data = if final_data do
          Map.put(updated_data, :final_data, sanitize_event_data(final_data))
        else
          updated_data
        end

        :ets.insert(@correlation_store, {correlation_id, updated_data})

        # Log status update
        Logger.info("Correlation status updated", %{
          event: "reqllm_correlation_status_update",
          correlation_id: correlation_id,
          status: status,
          duration_ms: updated_data.duration_ms,
          timestamp: timestamp
        })

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Retrieves correlation data by ID.

  ## Parameters
  - correlation_id: The correlation ID to retrieve

  ## Returns
  - {:ok, correlation_data} if found
  - {:error, :not_found} if not found
  """
  @spec get_correlation(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_correlation(correlation_id) do
    case :ets.lookup(@correlation_store, correlation_id) do
      [{^correlation_id, correlation_data}] ->
        {:ok, correlation_data}
      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets the full trace for a correlation ID.

  ## Parameters
  - correlation_id: The correlation ID to get the trace for

  ## Returns
  - {:ok, trace_summary} with detailed trace information
  - {:error, :not_found} if correlation ID doesn't exist
  """
  @spec get_trace(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_trace(correlation_id) do
    case get_correlation(correlation_id) do
      {:ok, correlation_data} ->
        trace_summary = %{
          correlation_id: correlation_id,
          status: correlation_data.status,
          created_at: correlation_data.created_at,
          completed_at: Map.get(correlation_data, :completed_at),
          duration_ms: Map.get(correlation_data, :duration_ms),
          components_involved: MapSet.to_list(correlation_data.components),
          total_events: length(correlation_data.trace_events),
          trace_events: correlation_data.trace_events,
          initial_context: correlation_data.initial_context,
          final_data: Map.get(correlation_data, :final_data)
        }

        {:ok, trace_summary}

      error ->
        error
    end
  end

  @doc """
  Searches for correlations by various criteria.

  ## Parameters
  - criteria: Search criteria map (provider, status, time_range, etc.)
  - limit: Maximum number of results (default: 100)

  ## Returns
  - List of matching correlation summaries
  """
  @spec search_correlations(map(), integer()) :: list(map())
  def search_correlations(criteria, limit \\ 100) do
    all_correlations = :ets.tab2list(@correlation_store)
    |> Enum.map(fn {_id, data} -> data end)

    filtered = Enum.filter(all_correlations, fn correlation ->
      matches_criteria?(correlation, criteria)
    end)

    filtered
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.take(limit)
    |> Enum.map(&build_correlation_summary/1)
  end

  @doc """
  Adds correlation ID to request headers for propagation.

  ## Parameters
  - headers: Existing headers list
  - correlation_id: Correlation ID to add

  ## Returns
  - Updated headers list with correlation ID
  """
  @spec add_correlation_header(list(), String.t()) :: list()
  def add_correlation_header(headers, correlation_id) when is_list(headers) do
    [{@correlation_header, correlation_id} | headers]
  end

  def add_correlation_header(headers, correlation_id) when is_map(headers) do
    Map.put(headers, @correlation_header, correlation_id)
  end

  @doc """
  Extracts correlation ID from request headers.

  ## Parameters
  - headers: Request headers (list or map)

  ## Returns
  - {:ok, correlation_id} if found
  - :not_found if not present
  """
  @spec extract_correlation_id(list() | map()) :: {:ok, String.t()} | :not_found
  def extract_correlation_id(headers) when is_list(headers) do
    case Enum.find(headers, fn {key, _value} ->
      String.downcase(key) == @correlation_header
    end) do
      {_key, correlation_id} -> {:ok, correlation_id}
      nil -> :not_found
    end
  end

  def extract_correlation_id(headers) when is_map(headers) do
    # Try both the exact header name and lowercase version
    case Map.get(headers, @correlation_header) || Map.get(headers, String.downcase(@correlation_header)) do
      nil -> :not_found
      correlation_id -> {:ok, correlation_id}
    end
  end

  @doc """
  Gets or creates a correlation ID for the current process.

  This function checks if there's already a correlation ID in the process dictionary,
  and if not, generates a new one and stores it.

  ## Returns
  - String correlation ID
  """
  @spec get_or_create_correlation_id() :: String.t()
  def get_or_create_correlation_id do
    case Process.get(:correlation_id) do
      nil ->
        correlation_id = generate_correlation_id()
        Process.put(:correlation_id, correlation_id)
        correlation_id

      existing_id ->
        existing_id
    end
  end

  @doc """
  Sets the correlation ID for the current process.

  ## Parameters
  - correlation_id: Correlation ID to set

  ## Returns
  - :ok
  """
  @spec set_correlation_id(String.t()) :: :ok
  def set_correlation_id(correlation_id) do
    Process.put(:correlation_id, correlation_id)
    :ok
  end

  @doc """
  Clears the correlation ID from the current process.

  ## Returns
  - :ok
  """
  @spec clear_correlation_id() :: :ok
  def clear_correlation_id do
    Process.delete(:correlation_id)
    :ok
  end

  @doc """
  Cleans up expired correlations.

  ## Returns
  - {:ok, cleaned_count} with number of cleaned correlations
  """
  @spec cleanup_expired_correlations() :: {:ok, integer()}
  def cleanup_expired_correlations do
    current_time = System.system_time(:millisecond)

    expired_keys = :ets.tab2list(@correlation_store)
    |> Enum.filter(fn {_id, data} -> data.ttl <= current_time end)
    |> Enum.map(fn {id, _data} -> id end)

    Enum.each(expired_keys, fn key ->
      :ets.delete(@correlation_store, key)
    end)

    Logger.info("Cleaned up #{length(expired_keys)} expired correlations")
    {:ok, length(expired_keys)}
  end

  @doc """
  Gets correlation statistics for monitoring.

  ## Parameters
  - time_window_ms: Time window for statistics in milliseconds (default: 1 hour)

  ## Returns
  - Map containing correlation statistics
  """
  @spec get_correlation_statistics(integer()) :: map()
  def get_correlation_statistics(time_window_ms \\ 3_600_000) do
    current_time = System.system_time(:millisecond)
    cutoff_time = current_time - time_window_ms

    correlations = :ets.tab2list(@correlation_store)
    |> Enum.filter(fn {_id, data} -> data.created_at >= cutoff_time end)
    |> Enum.map(fn {_id, data} -> data end)

    %{
      total_correlations: length(correlations),
      active_correlations: Enum.count(correlations, & &1.status == :active),
      completed_correlations: Enum.count(correlations, & &1.status == :completed),
      failed_correlations: Enum.count(correlations, & &1.status == :failed),
      average_duration_ms: calculate_average_duration(correlations),
      components_involved: get_unique_components(correlations),
      most_active_components: get_most_active_components(correlations)
    }
  end

  # Private Functions

  defp sanitize_context_for_logging(context) when is_map(context) do
    # Remove sensitive data from context before logging
    Map.drop(context, [:api_key, :token, :credentials, :password])
  end

  defp sanitize_context_for_logging(context), do: context

  defp sanitize_event_data(data) when is_map(data) do
    # Remove sensitive fields and truncate large data
    data
    |> Map.drop([:api_key, :token, :credentials, :password])
    |> truncate_map_values(500)
  end

  defp sanitize_event_data(data) when is_binary(data) do
    truncate_string(data, 1000)
  end

  defp sanitize_event_data(data) do
    inspect(data) |> truncate_string(500)
  end

  defp truncate_map_values(map, max_length) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      truncated_value = case value do
        v when is_binary(v) -> truncate_string(v, max_length)
        v when is_map(v) -> truncate_map_values(v, max_length)
        v -> v
      end
      Map.put(acc, key, truncated_value)
    end)
  end

  defp truncate_string(string, max_length) when is_binary(string) do
    if byte_size(string) > max_length do
      binary_part(string, 0, max_length) <> "... [truncated]"
    else
      string
    end
  end

  defp truncate_string(value, max_length) do
    inspect(value) |> truncate_string(max_length)
  end

  defp matches_criteria?(correlation, criteria) do
    Enum.all?(criteria, fn {key, value} ->
      case key do
        :provider ->
          get_in(correlation, [:initial_context, :provider]) == value

        :status ->
          correlation.status == value

        :component ->
          MapSet.member?(correlation.components, value)

        :time_range ->
          {start_time, end_time} = value
          correlation.created_at >= start_time and correlation.created_at <= end_time

        :duration_min ->
          Map.get(correlation, :duration_ms, 0) >= value

        :duration_max ->
          Map.get(correlation, :duration_ms, 0) <= value

        _ ->
          true  # Unknown criteria, ignore
      end
    end)
  end

  defp build_correlation_summary(correlation) do
    %{
      correlation_id: correlation.correlation_id,
      status: correlation.status,
      created_at: correlation.created_at,
      completed_at: Map.get(correlation, :completed_at),
      duration_ms: Map.get(correlation, :duration_ms),
      components: MapSet.to_list(correlation.components),
      event_count: length(correlation.trace_events),
      provider: get_in(correlation, [:initial_context, :provider]),
      operation: get_in(correlation, [:initial_context, :operation])
    }
  end

  defp calculate_average_duration(correlations) do
    completed = Enum.filter(correlations, & Map.has_key?(&1, :duration_ms))

    if length(completed) == 0 do
      0
    else
      total_duration = Enum.sum(Enum.map(completed, & &1.duration_ms))
      round(total_duration / length(completed))
    end
  end

  defp get_unique_components(correlations) do
    correlations
    |> Enum.flat_map(& MapSet.to_list(&1.components))
    |> Enum.uniq()
  end

  defp get_most_active_components(correlations) do
    correlations
    |> Enum.flat_map(& MapSet.to_list(&1.components))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_component, count} -> count end, :desc)
    |> Enum.take(5)
  end
end
