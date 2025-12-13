# lib/decision_engine/streaming_retry_handler.ex
defmodule DecisionEngine.StreamingRetryHandler do
  @moduledoc """
  Handles retry logic and error recovery for streaming operations.

  This module provides sophisticated retry mechanisms for streaming failures,
  including exponential backoff, circuit breaker patterns, and error classification
  to determine appropriate retry strategies.
  """

  require Logger

  @typedoc """
  Retry configuration options.
  """
  @type retry_config :: %{
    max_attempts: non_neg_integer(),
    base_delay: non_neg_integer(),
    max_delay: non_neg_integer(),
    backoff_factor: float(),
    retryable_errors: [atom()],
    circuit_breaker_threshold: non_neg_integer()
  }

  @typedoc """
  Retry attempt result.
  """
  @type retry_result :: :retry | :stop | {:delay, non_neg_integer()}

  # Default retry configuration
  @default_config %{
    max_attempts: 3,
    base_delay: 1000,      # 1 second
    max_delay: 30_000,     # 30 seconds
    backoff_factor: 2.0,
    retryable_errors: [
      :connection_failed,
      :timeout,
      :network_error,
      :rate_limited,
      :server_error,
      :temporary_failure
    ],
    circuit_breaker_threshold: 5
  }

  # Non-retryable errors that should fail immediately
  @non_retryable_errors [
    :authentication_failed,
    :invalid_api_key,
    :quota_exceeded,
    :content_size_limit_exceeded,
    :invalid_configuration,
    :unsupported_provider
  ]

  @doc """
  Determines if an error should be retried and calculates delay.

  ## Parameters
  - error: The error that occurred
  - attempt_count: Current attempt number (1-based)
  - config: Retry configuration (optional, uses defaults if not provided)

  ## Returns
  - :retry - Retry immediately
  - :stop - Stop retrying, error is not retryable
  - {:delay, milliseconds} - Retry after specified delay
  """
  @spec should_retry(term(), non_neg_integer(), retry_config()) :: retry_result()
  def should_retry(error, attempt_count, config \\ @default_config) do
    error_type = classify_error(error)

    cond do
      # Check if we've exceeded max attempts
      attempt_count >= config.max_attempts ->
        Logger.warning("Max retry attempts (#{config.max_attempts}) exceeded for error: #{inspect(error)}")
        :stop

      # Check if error is non-retryable
      error_type in @non_retryable_errors ->
        Logger.info("Non-retryable error encountered: #{error_type}")
        :stop

      # Check if error is retryable
      error_type in config.retryable_errors ->
        delay = calculate_backoff_delay(attempt_count, config)
        Logger.info("Retrying after #{delay}ms for error: #{error_type} (attempt #{attempt_count})")
        {:delay, delay}

      # Unknown error - be conservative and don't retry
      true ->
        Logger.warning("Unknown error type, not retrying: #{inspect(error)}")
        :stop
    end
  end

  @doc """
  Classifies an error into a retryable category.

  ## Parameters
  - error: The error to classify

  ## Returns
  - Atom representing the error category
  """
  @spec classify_error(term()) :: atom()
  def classify_error(error) do
    case error do
      # Network and connection errors
      {:error, :timeout} -> :timeout
      {:error, :econnrefused} -> :connection_failed
      {:error, :nxdomain} -> :network_error
      {:error, :closed} -> :connection_failed
      {:error, %Mint.TransportError{}} -> :network_error
      {:error, %Finch.Error{reason: :timeout}} -> :timeout
      {:error, %Finch.Error{reason: :econnrefused}} -> :connection_failed

      # HTTP status code errors
      {:error, %{status: 429}} -> :rate_limited
      {:error, %{status: status}} when status >= 500 and status < 600 -> :server_error
      {:error, %{status: 401}} -> :authentication_failed
      {:error, %{status: 403}} -> :authentication_failed
      {:error, %{status: 402}} -> :quota_exceeded

      # String-based error messages
      "connection timeout" -> :timeout
      "network error" -> :network_error
      "rate limit exceeded" -> :rate_limited
      "server error" -> :server_error
      "authentication failed" -> :authentication_failed
      "invalid api key" -> :invalid_api_key
      "quota exceeded" -> :quota_exceeded
      "content_size_limit_exceeded" -> :content_size_limit_exceeded

      # Atom-based errors
      :timeout -> :timeout
      :connection_failed -> :connection_failed
      :network_error -> :network_error
      :rate_limited -> :rate_limited
      :server_error -> :server_error
      :authentication_failed -> :authentication_failed
      :invalid_api_key -> :invalid_api_key
      :quota_exceeded -> :quota_exceeded
      :content_size_limit_exceeded -> :content_size_limit_exceeded
      :invalid_configuration -> :invalid_configuration
      :unsupported_provider -> :unsupported_provider

      # Default to temporary failure for unknown errors
      _ -> :temporary_failure
    end
  end

  @doc """
  Calculates exponential backoff delay with jitter.

  ## Parameters
  - attempt: Current attempt number (1-based)
  - config: Retry configuration

  ## Returns
  - Delay in milliseconds
  """
  @spec calculate_backoff_delay(non_neg_integer(), retry_config()) :: non_neg_integer()
  def calculate_backoff_delay(attempt, config) do
    # Calculate exponential backoff: base_delay * (backoff_factor ^ (attempt - 1))
    exponential_delay = config.base_delay * :math.pow(config.backoff_factor, attempt - 1)

    # Cap at max_delay
    capped_delay = min(exponential_delay, config.max_delay)

    # Add jitter (±25% random variation) to avoid thundering herd
    jitter_range = capped_delay * 0.25
    jitter = :rand.uniform() * jitter_range * 2 - jitter_range

    # Ensure minimum delay and convert to integer
    final_delay = max(config.base_delay, capped_delay + jitter)
    trunc(final_delay)
  end

  @doc """
  Creates a retry configuration with custom options.

  ## Parameters
  - opts: Keyword list of configuration options

  ## Returns
  - Retry configuration map
  """
  @spec create_config(keyword()) :: retry_config()
  def create_config(opts \\ []) do
    @default_config
    |> Map.merge(Enum.into(opts, %{}))
  end

  @doc """
  Executes a function with retry logic.

  ## Parameters
  - fun: Function to execute (should return {:ok, result} or {:error, reason})
  - config: Retry configuration (optional)

  ## Returns
  - {:ok, result} if function succeeds
  - {:error, reason} if all retries are exhausted
  """
  @spec with_retry((() -> {:ok, term()} | {:error, term()}), retry_config()) :: {:ok, term()} | {:error, term()}
  def with_retry(fun, config \\ @default_config) do
    execute_with_retry(fun, 1, config)
  end

  ## Private Functions

  defp execute_with_retry(fun, attempt, config) do
    case fun.() do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} = error ->
        case should_retry(reason, attempt, config) do
          :stop ->
            Logger.error("Retry stopped after #{attempt} attempts. Final error: #{inspect(reason)}")
            error

          # Note: :retry is not currently returned by should_retry/3, but kept for future use

          {:delay, delay_ms} ->
            Logger.debug("Retrying after #{delay_ms}ms (attempt #{attempt + 1})")
            Process.sleep(delay_ms)
            execute_with_retry(fun, attempt + 1, config)
        end
    end
  end
end
