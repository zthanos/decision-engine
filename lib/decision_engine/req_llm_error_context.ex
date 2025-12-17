# lib/decision_engine/req_llm_error_context.ex
defmodule DecisionEngine.ReqLLMErrorContext do
  @moduledoc """
  Comprehensive error context capture for ReqLLM integration.

  This module provides detailed error context collection, retry attempt tracking
  and logging, and error correlation and pattern analysis. It helps with
  debugging, monitoring, and improving system reliability.
  """

  require Logger
  alias DecisionEngine.ReqLLMLogger

  @error_context_store :req_llm_error_context_ets

  @doc """
  Initializes the error context capture system.

  ## Returns
  - :ok on successful initialization
  """
  @spec init() :: :ok
  def init do
    # Create ETS table for storing error contexts if it doesn't exist
    case :ets.whereis(@error_context_store) do
      :undefined ->
        :ets.new(@error_context_store, [:named_table, :public, :set, {:read_concurrency, true}])
      _ ->
        :ok
    end

    Logger.info("ReqLLM Error Context system initialized")
    :ok
  end

  @doc """
  Captures comprehensive error context for a failed request.

  ## Parameters
  - error: The error that occurred
  - request: Original request details
  - response: Response details (if any)
  - config: ReqLLM configuration
  - context: Request context including correlation_id, provider, operation
  - retry_info: Information about retry attempts (optional)

  ## Returns
  - {:ok, error_context_id} with unique identifier for the error context
  """
  @spec capture_error_context(term(), map(), map() | nil, map(), map(), map()) :: {:ok, String.t()}
  def capture_error_context(error, request, response, config, context, retry_info \\ %{}) do
    error_context_id = generate_error_context_id()
    timestamp = System.system_time(:millisecond)

    error_context = %{
      id: error_context_id,
      timestamp: timestamp,
      correlation_id: Map.get(context, :correlation_id),
      provider: Map.get(context, :provider),
      operation: Map.get(context, :operation),
      request_id: Map.get(context, :request_id),

      # Error details
      error: sanitize_error(error),
      error_type: classify_error_type(error),
      error_category: classify_error_category(error),

      # Request context
      request_details: sanitize_request_details(request),
      response_details: sanitize_response_details(response),
      config_details: sanitize_config_details(config),

      # Retry information
      retry_attempts: Map.get(retry_info, :attempts, 0),
      retry_delays: Map.get(retry_info, :delays, []),
      retry_errors: Map.get(retry_info, :previous_errors, []),

      # System context
      system_context: capture_system_context(),

      # Pattern analysis
      error_pattern: analyze_error_pattern(error, context),

      # Metadata
      created_at: timestamp,
      ttl: timestamp + (24 * 60 * 60 * 1000)  # 24 hours TTL
    }

    # Store error context
    :ets.insert(@error_context_store, {error_context_id, error_context})

    # Log the error with full context
    ReqLLMLogger.log_streaming_event(:error, error_context, context, [
      level: :error,
      include_request_body: true,
      include_response_body: true,
      include_headers: true
    ])

    # Update error patterns and statistics
    update_error_patterns(error_context)

    {:ok, error_context_id}
  end

  @doc """
  Tracks a retry attempt for an existing error context.

  ## Parameters
  - error_context_id: ID of the existing error context
  - attempt_number: Current retry attempt number
  - delay_ms: Delay before this retry attempt
  - error: Error from the retry attempt (if it failed)

  ## Returns
  - :ok on success
  - {:error, :not_found} if error context doesn't exist
  """
  @spec track_retry_attempt(String.t(), integer(), integer(), term() | nil) :: :ok | {:error, :not_found}
  def track_retry_attempt(error_context_id, attempt_number, delay_ms, error \\ nil) do
    case :ets.lookup(@error_context_store, error_context_id) do
      [{^error_context_id, error_context}] ->
        updated_context = error_context
        |> Map.update(:retry_attempts, attempt_number, fn _ -> attempt_number end)
        |> Map.update(:retry_delays, [delay_ms], fn delays -> delays ++ [delay_ms] end)
        |> Map.update(:retry_errors, [], fn errors ->
          if error, do: errors ++ [sanitize_error(error)], else: errors
        end)
        |> Map.put(:last_retry_at, System.system_time(:millisecond))

        :ets.insert(@error_context_store, {error_context_id, updated_context})

        # Log retry attempt
        Logger.warning("ReqLLM retry attempt #{attempt_number} for error context #{error_context_id}", %{
          event: "reqllm_retry_attempt",
          error_context_id: error_context_id,
          attempt_number: attempt_number,
          delay_ms: delay_ms,
          error: if(error, do: sanitize_error(error), else: nil),
          correlation_id: error_context.correlation_id,
          provider: error_context.provider
        })

        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Retrieves error context by ID.

  ## Parameters
  - error_context_id: ID of the error context to retrieve

  ## Returns
  - {:ok, error_context} if found
  - {:error, :not_found} if not found
  """
  @spec get_error_context(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_error_context(error_context_id) do
    case :ets.lookup(@error_context_store, error_context_id) do
      [{^error_context_id, error_context}] ->
        {:ok, error_context}
      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Analyzes error patterns for a specific provider or across all providers.

  ## Parameters
  - provider: Provider atom (optional, analyzes all if nil)
  - time_window_ms: Time window for analysis in milliseconds (default: 1 hour)

  ## Returns
  - Map containing error pattern analysis
  """
  @spec analyze_error_patterns(atom() | nil, integer()) :: map()
  def analyze_error_patterns(provider \\ nil, time_window_ms \\ 3_600_000) do
    current_time = System.system_time(:millisecond)
    cutoff_time = current_time - time_window_ms

    # Get all error contexts within the time window
    error_contexts = :ets.tab2list(@error_context_store)
    |> Enum.filter(fn {_id, context} ->
      context.timestamp >= cutoff_time and
      (is_nil(provider) or context.provider == provider)
    end)
    |> Enum.map(fn {_id, context} -> context end)

    %{
      total_errors: length(error_contexts),
      error_types: analyze_error_types(error_contexts),
      error_categories: analyze_error_categories(error_contexts),
      provider_breakdown: analyze_provider_breakdown(error_contexts),
      retry_patterns: analyze_retry_patterns(error_contexts),
      temporal_patterns: analyze_temporal_patterns(error_contexts),
      common_patterns: identify_common_patterns(error_contexts),
      recommendations: generate_recommendations(error_contexts)
    }
  end

  @doc """
  Gets error statistics for monitoring and alerting.

  ## Parameters
  - time_window_ms: Time window for statistics in milliseconds (default: 1 hour)

  ## Returns
  - Map containing error statistics
  """
  @spec get_error_statistics(integer()) :: map()
  def get_error_statistics(time_window_ms \\ 3_600_000) do
    current_time = System.system_time(:millisecond)
    cutoff_time = current_time - time_window_ms

    error_contexts = :ets.tab2list(@error_context_store)
    |> Enum.filter(fn {_id, context} -> context.timestamp >= cutoff_time end)
    |> Enum.map(fn {_id, context} -> context end)

    %{
      total_errors: length(error_contexts),
      error_rate: calculate_error_rate(error_contexts, time_window_ms),
      most_common_errors: get_most_common_errors(error_contexts),
      providers_with_errors: get_providers_with_errors(error_contexts),
      retry_success_rate: calculate_retry_success_rate(error_contexts),
      average_retry_attempts: calculate_average_retry_attempts(error_contexts)
    }
  end

  @doc """
  Cleans up expired error contexts.

  ## Returns
  - {:ok, cleaned_count} with number of cleaned contexts
  """
  @spec cleanup_expired_contexts() :: {:ok, integer()}
  def cleanup_expired_contexts do
    current_time = System.system_time(:millisecond)

    expired_keys = :ets.tab2list(@error_context_store)
    |> Enum.filter(fn {_id, context} -> context.ttl <= current_time end)
    |> Enum.map(fn {id, _context} -> id end)

    Enum.each(expired_keys, fn key ->
      :ets.delete(@error_context_store, key)
    end)

    Logger.info("Cleaned up #{length(expired_keys)} expired error contexts")
    {:ok, length(expired_keys)}
  end

  # Private Functions

  defp generate_error_context_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp classify_error_type(error) do
    case error do
      {:timeout, _} -> :timeout
      :timeout -> :timeout
      {:error, :timeout} -> :timeout
      {:error, :econnrefused} -> :connection_refused
      {:error, :nxdomain} -> :dns_error
      {:error, :closed} -> :connection_closed
      {:http_error, status, _} when status >= 500 -> :server_error
      {:http_error, status, _} when status >= 400 -> :client_error
      {:http_error, status, _} -> :http_error
      {:json_decode_error, _} -> :json_decode_error
      {:validation_error, _} -> :validation_error
      _ -> :unknown
    end
  end

  defp classify_error_category(error) do
    case classify_error_type(error) do
      type when type in [:timeout, :connection_refused, :connection_closed, :dns_error] ->
        :network

      type when type in [:server_error] ->
        :server

      type when type in [:client_error] ->
        :client

      type when type in [:json_decode_error, :validation_error] ->
        :data

      _ ->
        :unknown
    end
  end

  defp sanitize_error(error) do
    case error do
      {type, message} when is_binary(message) ->
        %{type: type, message: truncate_string(message, 500)}

      message when is_binary(message) ->
        %{message: truncate_string(message, 500)}

      {:http_error, status, headers, body} ->
        %{
          type: :http_error,
          status: status,
          headers: sanitize_headers(headers),
          body: truncate_string(inspect(body), 1000)
        }

      _ ->
        %{raw: truncate_string(inspect(error), 500)}
    end
  end

  defp sanitize_request_details(request) when is_map(request) do
    %{
      method: Map.get(request, :method),
      url: sanitize_url(Map.get(request, :url)),
      headers_count: count_headers(Map.get(request, :headers, [])),
      body_size: calculate_body_size(Map.get(request, :body)),
      timeout: Map.get(request, :timeout)
    }
  end

  defp sanitize_request_details(_), do: %{}

  defp sanitize_response_details(nil), do: nil

  defp sanitize_response_details(response) when is_map(response) do
    %{
      status: Map.get(response, :status),
      headers_count: count_headers(Map.get(response, :headers, [])),
      body_size: calculate_body_size(Map.get(response, :body)),
      response_time_ms: Map.get(response, :response_time_ms)
    }
  end

  defp sanitize_response_details(_), do: %{}

  defp sanitize_config_details(config) when is_map(config) do
    %{
      provider: Map.get(config, :provider),
      model: Map.get(config, :model),
      base_url: sanitize_url(Map.get(config, :base_url)),
      timeout: Map.get(config, :timeout),
      retry_enabled: Map.has_key?(config, :retry_strategy),
      connection_pool_enabled: Map.has_key?(config, :connection_pool)
    }
  end

  defp sanitize_config_details(_), do: %{}

  defp capture_system_context do
    %{
      node: Node.self(),
      memory_usage: :erlang.memory(:total),
      process_count: :erlang.system_info(:process_count),
      system_time: System.system_time(:millisecond),
      vm_memory: :erlang.memory()
    }
  end

  defp analyze_error_pattern(error, context) do
    %{
      error_type: classify_error_type(error),
      error_category: classify_error_category(error),
      provider: Map.get(context, :provider),
      operation: Map.get(context, :operation),
      time_of_day: extract_time_of_day(),
      day_of_week: extract_day_of_week()
    }
  end

  defp update_error_patterns(error_context) do
    # This could be expanded to update more sophisticated pattern tracking
    # For now, we'll just log the pattern for analysis
    Logger.debug("Error pattern recorded", %{
      event: "reqllm_error_pattern",
      pattern: error_context.error_pattern,
      correlation_id: error_context.correlation_id
    })
  end

  defp analyze_error_types(error_contexts) do
    error_contexts
    |> Enum.group_by(& &1.error_type)
    |> Enum.map(fn {type, contexts} -> {type, length(contexts)} end)
    |> Enum.into(%{})
  end

  defp analyze_error_categories(error_contexts) do
    error_contexts
    |> Enum.group_by(& &1.error_category)
    |> Enum.map(fn {category, contexts} -> {category, length(contexts)} end)
    |> Enum.into(%{})
  end

  defp analyze_provider_breakdown(error_contexts) do
    error_contexts
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, contexts} ->
      {provider, %{
        count: length(contexts),
        error_types: analyze_error_types(contexts)
      }}
    end)
    |> Enum.into(%{})
  end

  defp analyze_retry_patterns(error_contexts) do
    retry_contexts = Enum.filter(error_contexts, & &1.retry_attempts > 0)

    %{
      total_with_retries: length(retry_contexts),
      average_retry_attempts: calculate_average_retry_attempts(retry_contexts),
      retry_success_rate: calculate_retry_success_rate(retry_contexts),
      common_retry_delays: analyze_common_retry_delays(retry_contexts)
    }
  end

  defp analyze_temporal_patterns(error_contexts) do
    # Group errors by hour of day
    hourly_distribution = error_contexts
    |> Enum.group_by(fn context ->
      DateTime.from_unix!(context.timestamp, :millisecond)
      |> DateTime.to_time()
      |> Map.get(:hour)
    end)
    |> Enum.map(fn {hour, contexts} -> {hour, length(contexts)} end)
    |> Enum.into(%{})

    %{
      hourly_distribution: hourly_distribution,
      peak_error_hour: find_peak_hour(hourly_distribution)
    }
  end

  defp identify_common_patterns(error_contexts) do
    # Identify patterns that occur frequently
    patterns = error_contexts
    |> Enum.group_by(fn context ->
      "#{context.error_type}_#{context.provider}_#{context.operation}"
    end)
    |> Enum.filter(fn {_pattern, contexts} -> length(contexts) >= 3 end)
    |> Enum.map(fn {pattern, contexts} ->
      %{
        pattern: pattern,
        count: length(contexts),
        first_seen: Enum.min_by(contexts, & &1.timestamp).timestamp,
        last_seen: Enum.max_by(contexts, & &1.timestamp).timestamp
      }
    end)

    patterns
  end

  defp generate_recommendations(error_contexts) do
    recommendations = []

    # High retry rate recommendation
    recommendations = if calculate_average_retry_attempts(error_contexts) > 2 do
      ["Consider reviewing retry strategies - high average retry attempts detected" | recommendations]
    else
      recommendations
    end

    # Network error recommendation
    network_errors = Enum.count(error_contexts, & &1.error_category == :network)
    recommendations = if network_errors > length(error_contexts) * 0.3 do
      ["High network error rate detected - check network connectivity and timeouts" | recommendations]
    else
      recommendations
    end

    # Provider-specific recommendations
    provider_errors = analyze_provider_breakdown(error_contexts)
    recommendations = Enum.reduce(provider_errors, recommendations, fn {provider, data}, acc ->
      if data.count > 5 do
        ["Review #{provider} provider configuration - high error count" | acc]
      else
        acc
      end
    end)

    recommendations
  end

  # Helper functions

  defp sanitize_headers(headers) when is_list(headers) do
    length(headers)
  end

  defp sanitize_headers(_), do: 0

  defp sanitize_url(url) when is_binary(url) do
    # Remove query parameters and keep only the base URL
    case String.split(url, "?", parts: 2) do
      [base_url, _] -> base_url
      [base_url] -> base_url
    end
  end

  defp sanitize_url(_), do: nil

  defp count_headers(headers) when is_list(headers), do: length(headers)
  defp count_headers(_), do: 0

  defp calculate_body_size(body) when is_binary(body), do: byte_size(body)
  defp calculate_body_size(body) when is_map(body) do
    body |> Jason.encode!() |> byte_size()
  rescue
    _ -> 0
  end
  defp calculate_body_size(_), do: 0

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

  defp extract_time_of_day do
    DateTime.utc_now() |> DateTime.to_time() |> Map.get(:hour)
  end

  defp extract_day_of_week do
    Date.day_of_week(Date.utc_today())
  end

  defp calculate_error_rate(error_contexts, time_window_ms) do
    if length(error_contexts) == 0 do
      0.0
    else
      # This is a simplified calculation - in a real system you'd need total request count
      length(error_contexts) / (time_window_ms / 1000 / 60)  # errors per minute
    end
  end

  defp get_most_common_errors(error_contexts) do
    error_contexts
    |> Enum.group_by(& &1.error_type)
    |> Enum.map(fn {type, contexts} -> {type, length(contexts)} end)
    |> Enum.sort_by(fn {_type, count} -> count end, :desc)
    |> Enum.take(5)
  end

  defp get_providers_with_errors(error_contexts) do
    error_contexts
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
  end

  defp calculate_retry_success_rate(error_contexts) do
    retry_contexts = Enum.filter(error_contexts, & &1.retry_attempts > 0)

    if length(retry_contexts) == 0 do
      0.0
    else
      # This is simplified - in reality you'd track final success/failure
      successful_retries = Enum.count(retry_contexts, fn context ->
        length(context.retry_errors) < context.retry_attempts
      end)

      successful_retries / length(retry_contexts)
    end
  end

  defp calculate_average_retry_attempts(error_contexts) do
    retry_contexts = Enum.filter(error_contexts, & &1.retry_attempts > 0)

    if length(retry_contexts) == 0 do
      0.0
    else
      total_attempts = Enum.sum(Enum.map(retry_contexts, & &1.retry_attempts))
      total_attempts / length(retry_contexts)
    end
  end

  defp analyze_common_retry_delays(error_contexts) do
    error_contexts
    |> Enum.flat_map(& &1.retry_delays)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_delay, count} -> count end, :desc)
    |> Enum.take(5)
  end

  defp find_peak_hour(hourly_distribution) do
    case Enum.max_by(hourly_distribution, fn {_hour, count} -> count end, fn -> nil end) do
      {hour, _count} -> hour
      nil -> nil
    end
  end
end
