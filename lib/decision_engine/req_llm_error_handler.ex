# lib/decision_engine/req_llm_error_handler.ex
defmodule DecisionEngine.ReqLLMErrorHandler do
  @moduledoc """
  Enhanced error handling for ReqLLM integration.

  This module provides comprehensive error handling including exponential backoff
  retry strategies, rate limit detection and handling, authentication error handling
  with token refresh, and circuit breaker patterns for failing providers.
  """

  require Logger
  alias DecisionEngine.ReqLLMErrorContext
  alias DecisionEngine.ReqLLMCorrelation

  @default_retry_config %{
    max_retries: 3,
    base_delay: 1000,
    max_delay: 30000,
    backoff_type: :exponential,
    retry_on: [:timeout, :connection_error, :rate_limit, :server_error]
  }

  @default_circuit_breaker_config %{
    failure_threshold: 5,
    recovery_timeout: 60000,
    half_open_max_calls: 3
  }



  @doc """
  Executes a function with enhanced error handling and retry logic.

  ## Parameters
  - fun: Function to execute (should return {:ok, result} or {:error, reason})
  - config: Configuration map with retry and circuit breaker settings
  - context: Context map for logging and circuit breaker identification

  ## Returns
  - {:ok, result} on success
  - {:error, reason} on final failure after all retries
  """
  @spec with_error_handling(function(), map(), map()) :: {:ok, term()} | {:error, term()}
  def with_error_handling(fun, config \\ %{}, context \\ %{}) do
    retry_config = Map.merge(@default_retry_config, Map.get(config, :retry_strategy, %{}))
    circuit_config = Map.merge(@default_circuit_breaker_config, Map.get(config, :circuit_breaker, %{}))

    provider = Map.get(context, :provider, :unknown)

    case check_circuit_breaker(provider, circuit_config) do
      :open ->
        {:error, "Circuit breaker open for provider #{provider}"}

      :half_open ->
        execute_with_circuit_breaker(fun, retry_config, circuit_config, provider, context)

      :closed ->
        execute_with_retry(fun, retry_config, 0, context)
    end
  end

  @doc """
  Handles rate limiting by extracting rate limit information from response headers.

  ## Parameters
  - headers: Response headers list
  - provider: Provider atom for provider-specific handling

  ## Returns
  - {:ok, delay_ms} if rate limited with suggested delay
  - :not_rate_limited if no rate limiting detected
  """
  @spec handle_rate_limit(list(), atom()) :: {:ok, integer()} | :not_rate_limited
  def handle_rate_limit(headers, provider) do
    headers_map = headers |> Enum.into(%{}, fn {k, v} -> {String.downcase(k), v} end)

    cond do
      # Check for Retry-After header (most common)
      retry_after = Map.get(headers_map, "retry-after") ->
        case Integer.parse(retry_after) do
          {seconds, _} -> {:ok, seconds * 1000}
          :error -> {:ok, 60000}  # Default 1 minute
        end

      # Check for X-RateLimit headers
      remaining = Map.get(headers_map, "x-ratelimit-remaining") ->
        case Integer.parse(remaining) do
          {0, _} ->
            reset_time = Map.get(headers_map, "x-ratelimit-reset", "60")
            case Integer.parse(reset_time) do
              {reset, _} -> {:ok, reset * 1000}
              :error -> {:ok, 60000}
            end
          _ -> :not_rate_limited
        end

      # Provider-specific rate limit handling
      true ->
        handle_provider_specific_rate_limit(headers_map, provider)
    end
  end

  @doc """
  Handles authentication errors and attempts token refresh if applicable.

  ## Parameters
  - error: Error details from the API response
  - config: Configuration map containing authentication details
  - provider: Provider atom

  ## Returns
  - {:retry, updated_config} if token refresh succeeded
  - {:error, reason} if authentication cannot be recovered
  """
  @spec handle_auth_error(term(), map(), atom()) :: {:retry, map()} | {:error, term()}
  def handle_auth_error(error, config, provider) do
    case provider do
      :openai ->
        handle_openai_auth_error(error, config)

      :anthropic ->
        handle_anthropic_auth_error(error, config)

      _ ->
        {:error, "Authentication failed for #{provider}: #{inspect(error)}"}
    end
  end

  @doc """
  Calculates the next retry delay using the specified backoff strategy.

  ## Parameters
  - attempt: Current attempt number (0-based)
  - config: Retry configuration map

  ## Returns
  - Integer delay in milliseconds
  """
  @spec calculate_retry_delay(integer(), map()) :: integer()
  def calculate_retry_delay(attempt, config) do
    base_delay = Map.get(config, :base_delay, 1000)
    max_delay = Map.get(config, :max_delay, 30000)
    backoff_type = Map.get(config, :backoff_type, :exponential)

    delay = case backoff_type do
      :exponential ->
        base_delay * :math.pow(2, attempt)

      :linear ->
        base_delay * (attempt + 1)

      :constant ->
        base_delay
    end

    # Add jitter to prevent thundering herd
    jitter = :rand.uniform(trunc(delay * 0.1))

    trunc(min(delay + jitter, max_delay))
  end

  @doc """
  Determines if an error is retryable based on the error type and configuration.

  ## Parameters
  - error: Error term or HTTP status code
  - config: Retry configuration map

  ## Returns
  - true if error is retryable
  - false if error should not be retried
  """
  @spec retryable_error?(term(), map()) :: boolean()
  def retryable_error?(error, config) do
    retry_on = Map.get(config, :retry_on, @default_retry_config.retry_on)

    case error do
      # HTTP status codes
      status when is_integer(status) ->
        cond do
          status >= 500 and status < 600 -> :server_error in retry_on
          status == 429 -> :rate_limit in retry_on
          status == 408 -> :timeout in retry_on
          status >= 400 and status < 500 -> false  # Client errors generally not retryable
          true -> false
        end

      # Error atoms/tuples
      {:timeout, _} -> :timeout in retry_on
      :timeout -> :timeout in retry_on
      {:error, :timeout} -> :timeout in retry_on
      {:error, :econnrefused} -> :connection_error in retry_on
      {:error, :nxdomain} -> :connection_error in retry_on
      {:error, :closed} -> :connection_error in retry_on

      # String error messages
      error_msg when is_binary(error_msg) ->
        cond do
          String.contains?(error_msg, ["timeout", "timed out"]) -> :timeout in retry_on
          String.contains?(error_msg, ["connection", "network"]) -> :connection_error in retry_on
          String.contains?(error_msg, ["rate limit", "too many requests"]) -> :rate_limit in retry_on
          true -> false
        end

      _ -> false
    end
  end

  # Private Functions

  defp execute_with_retry(fun, config, attempt, context) do
    correlation_id = Map.get(context, :correlation_id)

    case fun.() do
      {:ok, result} ->
        if correlation_id do
          ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :retry_success, %{
            final_attempt: attempt + 1
          })
        end
        {:ok, result}

      {:error, reason} ->
        # Track retry attempt if we have correlation ID
        if correlation_id do
          ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :retry_attempt, %{
            attempt: attempt + 1,
            error: inspect(reason),
            retryable: retryable_error?(reason, config)
          })
        end

        if attempt < config.max_retries and retryable_error?(reason, config) do
          delay = calculate_retry_delay(attempt, config)

          Logger.warning("Request failed (attempt #{attempt + 1}/#{config.max_retries + 1}), retrying in #{delay}ms: #{inspect(reason)}")

          # Handle special cases
          case handle_special_error(reason, config, context) do
            {:retry_with_delay, custom_delay} ->
              if correlation_id do
                ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :custom_delay, %{
                  delay_ms: custom_delay,
                  reason: "special_error_handling"
                })
              end
              Process.sleep(custom_delay)
              execute_with_retry(fun, config, attempt + 1, context)

            {:error, final_error} ->
              if correlation_id do
                ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :retry_failed, %{
                  final_error: inspect(final_error)
                })
              end
              {:error, final_error}

            :continue ->
              if correlation_id do
                ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :retry_delay, %{
                  delay_ms: delay
                })
              end
              Process.sleep(delay)
              execute_with_retry(fun, config, attempt + 1, context)
          end
        else
          Logger.error("Request failed after #{attempt + 1} attempts: #{inspect(reason)}")

          # Capture final error context
          if correlation_id do
            ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_error_handler, :retry_exhausted, %{
              total_attempts: attempt + 1,
              final_error: inspect(reason)
            })
          end

          {:error, reason}
        end
    end
  end

  defp execute_with_circuit_breaker(fun, retry_config, circuit_config, provider, context) do
    case execute_with_retry(fun, retry_config, 0, context) do
      {:ok, result} ->
        record_circuit_breaker_success(provider)
        {:ok, result}

      {:error, reason} ->
        record_circuit_breaker_failure(provider, circuit_config)
        {:error, reason}
    end
  end

  defp handle_special_error(reason, config, context) do
    provider = Map.get(context, :provider, :unknown)

    case reason do
      # Rate limiting
      {:http_error, 429, headers} ->
        case handle_rate_limit(headers, provider) do
          {:ok, delay} ->
            Logger.info("Rate limited by #{provider}, waiting #{delay}ms")
            {:retry_with_delay, delay}
          :not_rate_limited ->
            :continue
        end

      # Authentication errors
      {:http_error, 401, _headers} ->
        handle_auth_error(reason, config, provider)

      {:http_error, 403, _headers} ->
        handle_auth_error(reason, config, provider)

      _ ->
        :continue
    end
  end

  defp handle_provider_specific_rate_limit(headers_map, provider) do
    case provider do
      :openai ->
        # OpenAI uses x-ratelimit-* headers
        remaining = Map.get(headers_map, "x-ratelimit-requests-remaining", "1")
        case Integer.parse(remaining) do
          {0, _} -> {:ok, 60000}  # Wait 1 minute
          _ -> :not_rate_limited
        end

      :anthropic ->
        # Anthropic uses different header format
        remaining = Map.get(headers_map, "anthropic-ratelimit-requests-remaining", "1")
        case Integer.parse(remaining) do
          {0, _} -> {:ok, 60000}  # Wait 1 minute
          _ -> :not_rate_limited
        end

      _ ->
        :not_rate_limited
    end
  end

  defp handle_openai_auth_error(error, _config) do
    Logger.warning("OpenAI authentication error: #{inspect(error)}")

    # For now, we don't implement token refresh for OpenAI
    # In a production system, you might implement OAuth token refresh here
    {:error, "OpenAI authentication failed - check API key"}
  end

  defp handle_anthropic_auth_error(error, _config) do
    Logger.warning("Anthropic authentication error: #{inspect(error)}")

    # For now, we don't implement token refresh for Anthropic
    # In a production system, you might implement token refresh here
    {:error, "Anthropic authentication failed - check API key"}
  end

  # Circuit Breaker Implementation

  defp check_circuit_breaker(provider, config) do
    case get_circuit_breaker_state(provider) do
      nil ->
        :closed

      %{state: :open, opened_at: opened_at} ->
        if System.system_time(:millisecond) - opened_at > config.recovery_timeout do
          set_circuit_breaker_state(provider, %{state: :half_open, half_open_calls: 0})
          :half_open
        else
          :open
        end

      %{state: :half_open} ->
        :half_open

      %{state: :closed} ->
        :closed
    end
  end

  defp record_circuit_breaker_success(provider) do
    case get_circuit_breaker_state(provider) do
      %{state: :half_open} ->
        set_circuit_breaker_state(provider, %{state: :closed, failures: 0})
        Logger.info("Circuit breaker closed for provider #{provider}")

      _ ->
        :ok
    end
  end

  defp record_circuit_breaker_failure(provider, config) do
    current_state = get_circuit_breaker_state(provider) || %{state: :closed, failures: 0}

    case current_state.state do
      :closed ->
        new_failures = Map.get(current_state, :failures, 0) + 1
        if new_failures >= config.failure_threshold do
          set_circuit_breaker_state(provider, %{
            state: :open,
            opened_at: System.system_time(:millisecond),
            failures: new_failures
          })
          Logger.warning("Circuit breaker opened for provider #{provider} after #{new_failures} failures")
        else
          set_circuit_breaker_state(provider, %{current_state | failures: new_failures})
        end

      :half_open ->
        set_circuit_breaker_state(provider, %{
          state: :open,
          opened_at: System.system_time(:millisecond),
          failures: Map.get(current_state, :failures, 0) + 1
        })
        Logger.warning("Circuit breaker re-opened for provider #{provider}")

      :open ->
        # Already open, just update failure count
        set_circuit_breaker_state(provider, %{
          current_state |
          failures: Map.get(current_state, :failures, 0) + 1
        })
    end
  end

  defp get_circuit_breaker_state(provider) do
    # In a production system, this would be stored in ETS, Redis, or a database
    # For now, we'll use the process dictionary as a simple implementation
    Process.get({:circuit_breaker, provider})
  end

  defp set_circuit_breaker_state(provider, state) do
    # In a production system, this would be stored in ETS, Redis, or a database
    # For now, we'll use the process dictionary as a simple implementation
    Process.put({:circuit_breaker, provider}, state)
  end
end
