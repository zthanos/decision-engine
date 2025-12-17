# lib/decision_engine/req_llm_logger.ex
defmodule DecisionEngine.ReqLLMLogger do
  @moduledoc """
  Enhanced logging system for ReqLLM integration.

  This module provides detailed request/response logging with configurable verbosity levels,
  log filtering, and structured log format for automated analysis. It supports different
  log levels and formats to meet various operational and debugging needs.
  """

  require Logger

  @log_levels [:debug, :info, :warning, :error]
  @default_config %{
    level: :info,
    include_request_body: false,
    include_response_body: false,
    include_headers: false,
    max_body_size: 1000,
    redact_sensitive: true,
    structured_format: true
  }

  @sensitive_headers [
    "authorization",
    "x-api-key",
    "anthropic-version",
    "cookie",
    "set-cookie"
  ]

  @sensitive_body_fields [
    "api_key",
    "token",
    "password",
    "secret"
  ]

  @doc """
  Logs credential operations for security auditing.

  ## Parameters
  - operation: The credential operation (:store, :retrieve, :rotate, :validate, :refresh, :delete)
  - provider: The LLM provider (atom or nil)
  - credential_type: The type of credential (atom or nil)
  - metadata: Additional operation metadata

  ## Returns
  - :ok
  """
  @spec log_credential_operation(atom(), atom() | nil, atom() | nil, map()) :: :ok
  def log_credential_operation(operation, provider, credential_type, metadata \\ %{}) do
    log_data = %{
      event_type: :credential_operation,
      operation: operation,
      provider: provider,
      credential_type: credential_type,
      timestamp: DateTime.utc_now(),
      success: Map.get(metadata, :success, false),
      metadata: sanitize_credential_metadata(metadata)
    }

    case Map.get(metadata, :success, false) do
      true ->
        Logger.info("Credential operation successful", log_data)
      false ->
        Logger.warning("Credential operation failed", log_data)
    end

    :ok
  end

  @doc """
  Logs security events for monitoring and auditing.

  ## Parameters
  - event_type: The type of security event
  - metadata: Event metadata and context

  ## Returns
  - :ok
  """
  @spec log_security_event(atom(), map()) :: :ok
  def log_security_event(event_type, metadata \\ %{}) do
    log_data = %{
      event_type: :security_event,
      security_event: event_type,
      timestamp: DateTime.utc_now(),
      success: Map.get(metadata, :success, true),
      metadata: sanitize_security_metadata(metadata)
    }

    case Map.get(metadata, :success, true) do
      true ->
        Logger.info("Security event: #{event_type}", log_data)
      false ->
        Logger.warning("Security event failed: #{event_type}", log_data)
    end

    :ok
  end

  @doc """
  Logs a ReqLLM request with configurable detail level.

  ## Parameters
  - request: Request map containing method, url, headers, body
  - config: ReqLLM configuration map
  - context: Request context including correlation_id, provider, operation
  - opts: Logging options (optional)

  ## Returns
  - :ok
  """
  @spec log_request(map(), map(), map(), keyword()) :: :ok
  def log_request(request, config, context, opts \\ []) do
    log_config = build_log_config(opts)

    if should_log?(:info, log_config.level) do
      log_data = %{
        event: "reqllm_request",
        correlation_id: Map.get(context, :correlation_id),
        provider: Map.get(context, :provider),
        operation: Map.get(context, :operation),
        request_id: Map.get(context, :request_id),
        method: request.method,
        url: sanitize_url(request.url),
        timestamp: System.system_time(:millisecond)
      }

      log_data = maybe_add_headers(log_data, request.headers, log_config)
      log_data = maybe_add_request_body(log_data, request.body, log_config)

      if log_config.structured_format do
        Logger.info("ReqLLM Request", log_data)
      else
        message = format_request_message(log_data)
        Logger.info(message)
      end
    end

    :ok
  end

  @doc """
  Logs a ReqLLM response with configurable detail level.

  ## Parameters
  - response: Response map containing status, headers, body
  - config: ReqLLM configuration map
  - context: Request context including correlation_id, provider, operation
  - duration_ms: Request duration in milliseconds
  - opts: Logging options (optional)

  ## Returns
  - :ok
  """
  @spec log_response(map(), map(), map(), integer(), keyword()) :: :ok
  def log_response(response, config, context, duration_ms, opts \\ []) do
    log_config = build_log_config(opts)

    log_level = determine_response_log_level(response)

    if should_log?(log_level, log_config.level) do
      log_data = %{
        event: "reqllm_response",
        correlation_id: Map.get(context, :correlation_id),
        provider: Map.get(context, :provider),
        operation: Map.get(context, :operation),
        request_id: Map.get(context, :request_id),
        status: Map.get(response, :status),
        duration_ms: duration_ms,
        timestamp: System.system_time(:millisecond)
      }

      log_data = maybe_add_headers(log_data, Map.get(response, :headers, []), log_config)
      log_data = maybe_add_response_body(log_data, Map.get(response, :body), log_config)
      log_data = maybe_add_response_metadata(log_data, response)

      if log_config.structured_format do
        Logger.log(log_level, "ReqLLM Response", log_data)
      else
        message = format_response_message(log_data)
        Logger.log(log_level, message)
      end
    end

    :ok
  end

  @doc """
  Logs streaming events with detailed context.

  ## Parameters
  - event: Streaming event type (:start, :chunk, :complete, :error)
  - data: Event-specific data
  - context: Request context including correlation_id, provider, operation
  - opts: Logging options (optional)

  ## Returns
  - :ok
  """
  @spec log_streaming_event(atom(), term(), map(), keyword()) :: :ok
  def log_streaming_event(event, data, context, opts \\ []) do
    log_config = build_log_config(opts)

    log_level = determine_streaming_log_level(event)

    if should_log?(log_level, log_config.level) do
      log_data = %{
        event: "reqllm_streaming_#{event}",
        correlation_id: Map.get(context, :correlation_id),
        provider: Map.get(context, :provider),
        operation: Map.get(context, :operation),
        request_id: Map.get(context, :request_id),
        stream_ref: Map.get(context, :stream_ref),
        timestamp: System.system_time(:millisecond)
      }

      log_data = add_streaming_data(log_data, event, data, log_config)

      if log_config.structured_format do
        Logger.log(log_level, "ReqLLM Streaming #{String.capitalize(to_string(event))}", log_data)
      else
        message = format_streaming_message(log_data, event)
        Logger.log(log_level, message)
      end
    end

    :ok
  end

  @doc """
  Logs performance metrics for ReqLLM operations.

  ## Parameters
  - metrics: Performance metrics map
  - context: Request context including correlation_id, provider, operation
  - opts: Logging options (optional)

  ## Returns
  - :ok
  """
  @spec log_performance_metrics(map(), map(), keyword()) :: :ok
  def log_performance_metrics(metrics, context, opts \\ []) do
    log_config = build_log_config(opts)

    if should_log?(:info, log_config.level) do
      log_data = %{
        event: "reqllm_performance_metrics",
        correlation_id: Map.get(context, :correlation_id),
        provider: Map.get(context, :provider),
        operation: Map.get(context, :operation),
        request_id: Map.get(context, :request_id),
        timestamp: System.system_time(:millisecond)
      }

      log_data = Map.merge(log_data, sanitize_metrics(metrics))

      if log_config.structured_format do
        Logger.info("ReqLLM Performance Metrics", log_data)
      else
        message = format_metrics_message(log_data)
        Logger.info(message)
      end
    end

    :ok
  end

  @doc """
  Configures the logging system with new settings.

  ## Parameters
  - config: Configuration map with logging settings

  ## Returns
  - :ok
  """
  @spec configure_logging(map()) :: :ok
  def configure_logging(config) do
    # Store configuration in application environment
    current_config = Application.get_env(:decision_engine, :req_llm_logging, @default_config)
    new_config = Map.merge(current_config, config)

    Application.put_env(:decision_engine, :req_llm_logging, new_config)

    Logger.info("ReqLLM logging configuration updated", %{
      event: "reqllm_logging_config_updated",
      config: sanitize_config_for_logging(new_config),
      timestamp: System.system_time(:millisecond)
    })

    :ok
  end

  @doc """
  Gets the current logging configuration.

  ## Returns
  - Configuration map
  """
  @spec get_logging_config() :: map()
  def get_logging_config do
    Application.get_env(:decision_engine, :req_llm_logging, @default_config)
  end

  # Private Functions

  defp build_log_config(opts) do
    base_config = get_logging_config()
    Enum.reduce(opts, base_config, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp should_log?(message_level, config_level) do
    level_priority = %{debug: 0, info: 1, warning: 2, error: 3}
    Map.get(level_priority, message_level, 1) >= Map.get(level_priority, config_level, 1)
  end

  defp determine_response_log_level(response) do
    case Map.get(response, :status) do
      status when status >= 500 -> :error
      status when status >= 400 -> :warning
      _ -> :info
    end
  end

  defp determine_streaming_log_level(event) do
    case event do
      :error -> :error
      :start -> :info
      :complete -> :info
      :chunk -> :debug
      _ -> :info
    end
  end

  defp sanitize_url(url) when is_binary(url) do
    # Remove query parameters that might contain sensitive data
    case String.split(url, "?", parts: 2) do
      [base_url, _query] -> base_url
      [base_url] -> base_url
    end
  end

  defp sanitize_url(url), do: inspect(url)

  defp maybe_add_headers(log_data, headers, config) do
    if config.include_headers do
      sanitized_headers = sanitize_headers(headers, config.redact_sensitive)
      Map.put(log_data, :headers, sanitized_headers)
    else
      log_data
    end
  end

  defp maybe_add_request_body(log_data, body, config) do
    if config.include_request_body and not is_nil(body) do
      sanitized_body = sanitize_body(body, config)
      Map.put(log_data, :request_body, sanitized_body)
    else
      log_data
    end
  end

  defp maybe_add_response_body(log_data, body, config) do
    if config.include_response_body and not is_nil(body) do
      sanitized_body = sanitize_body(body, config)
      Map.put(log_data, :response_body, sanitized_body)
    else
      log_data
    end
  end

  defp maybe_add_response_metadata(log_data, response) do
    metadata = %{}

    # Add content length if available
    metadata = case Map.get(response, :body) do
      body when is_binary(body) -> Map.put(metadata, :content_length, byte_size(body))
      _ -> metadata
    end

    # Add response time if available
    metadata = case Map.get(response, :response_time_ms) do
      time when is_integer(time) -> Map.put(metadata, :response_time_ms, time)
      _ -> metadata
    end

    if map_size(metadata) > 0 do
      Map.put(log_data, :metadata, metadata)
    else
      log_data
    end
  end

  defp add_streaming_data(log_data, event, data, config) do
    case event do
      :start ->
        Map.put(log_data, :stream_started, true)

      :chunk ->
        chunk_info = %{
          chunk_size: if(is_binary(data), do: byte_size(data), else: 0),
          chunk_preview: if(config.include_response_body and is_binary(data),
                           do: truncate_content(data, 100),
                           else: nil)
        }
        Map.put(log_data, :chunk_info, chunk_info)

      :complete ->
        completion_info = case data do
          %{total_chunks: chunks, total_bytes: bytes, duration_ms: duration} ->
            %{total_chunks: chunks, total_bytes: bytes, duration_ms: duration}
          _ ->
            %{completed: true}
        end
        Map.put(log_data, :completion_info, completion_info)

      :error ->
        error_info = %{
          error_type: classify_error(data),
          error_message: sanitize_error_message(data)
        }
        Map.put(log_data, :error_info, error_info)

      _ ->
        Map.put(log_data, :event_data, inspect(data))
    end
  end

  defp sanitize_headers(headers, redact_sensitive) when is_list(headers) do
    if redact_sensitive do
      Enum.map(headers, fn {key, value} ->
        if String.downcase(key) in @sensitive_headers do
          {key, "[REDACTED]"}
        else
          {key, value}
        end
      end)
    else
      headers
    end
  end

  defp sanitize_headers(headers, _), do: headers

  defp sanitize_body(body, config) when is_map(body) do
    body
    |> Jason.encode!()
    |> sanitize_json_body(config)
  end

  defp sanitize_body(body, config) when is_binary(body) do
    sanitize_json_body(body, config)
  end

  defp sanitize_body(body, _config), do: inspect(body)

  defp sanitize_json_body(json_string, config) when is_binary(json_string) do
    # Truncate if too long
    truncated = truncate_content(json_string, config.max_body_size)

    # Redact sensitive fields if enabled
    if config.redact_sensitive do
      redact_sensitive_json_fields(truncated)
    else
      truncated
    end
  end

  defp sanitize_credential_metadata(metadata) do
    # Remove sensitive credential information from metadata
    sensitive_keys = [:credential_value, :api_key, :token, :secret, :password, :refresh_token]

    metadata
    |> Map.drop(sensitive_keys)
    |> Enum.into(%{}, fn {key, value} ->
      case key do
        :credential_id -> {key, mask_credential_id(value)}
        :old_credential_id -> {key, mask_credential_id(value)}
        :new_credential_id -> {key, mask_credential_id(value)}
        _ -> {key, value}
      end
    end)
  end

  defp mask_credential_id(nil), do: nil
  defp mask_credential_id(id) when is_binary(id) do
    case String.length(id) do
      len when len <= 8 -> String.duplicate("*", len)
      len -> String.slice(id, 0, 4) <> String.duplicate("*", len - 8) <> String.slice(id, -4, 4)
    end
  end
  defp mask_credential_id(id), do: inspect(id)

  defp sanitize_security_metadata(metadata) do
    # Remove sensitive security information from metadata
    sensitive_keys = [:credentials, :api_key, :token, :certificate_data, :private_key]

    metadata
    |> Map.drop(sensitive_keys)
    |> Enum.into(%{}, fn {key, value} ->
      case key do
        :url -> {key, sanitize_url_for_logging(value)}
        :host -> {key, value}
        :fingerprint -> {key, mask_fingerprint(value)}
        _ -> {key, value}
      end
    end)
  end

  defp sanitize_url_for_logging(nil), do: nil
  defp sanitize_url_for_logging(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} -> "#{host}#{path || "/"}"
      _ -> "[invalid_url]"
    end
  end
  defp sanitize_url_for_logging(url), do: inspect(url)

  defp mask_fingerprint(nil), do: nil
  defp mask_fingerprint(fingerprint) when is_binary(fingerprint) do
    case String.length(fingerprint) do
      len when len <= 8 -> String.duplicate("*", len)
      len -> String.slice(fingerprint, 0, 4) <> "..." <> String.slice(fingerprint, -4, 4)
    end
  end
  defp mask_fingerprint(fingerprint), do: inspect(fingerprint)

  defp redact_sensitive_json_fields(json_string) do
    # Simple regex-based redaction for common sensitive fields
    Enum.reduce(@sensitive_body_fields, json_string, fn field, acc ->
      # Match "field": "value" or "field":"value"
      pattern = ~r/"#{field}"\s*:\s*"[^"]*"/i
      String.replace(acc, pattern, "\"#{field}\": \"[REDACTED]\"")
    end)
  end

  defp truncate_content(content, max_size) when is_binary(content) do
    if byte_size(content) > max_size do
      binary_part(content, 0, max_size) <> "... [truncated]"
    else
      content
    end
  end

  defp truncate_content(content, _max_size), do: inspect(content)

  defp sanitize_metrics(metrics) when is_map(metrics) do
    # Remove any potentially sensitive data from metrics
    Map.drop(metrics, [:api_key, :token, :credentials])
  end

  defp sanitize_metrics(metrics), do: %{raw_metrics: inspect(metrics)}

  defp sanitize_config_for_logging(config) do
    # Remove sensitive configuration values from logs
    Map.drop(config, [:api_key, :token, :credentials])
  end

  defp classify_error(error) do
    case error do
      {:timeout, _} -> :timeout
      :timeout -> :timeout
      {:error, :timeout} -> :timeout
      {:error, :econnrefused} -> :connection_error
      {:error, :nxdomain} -> :dns_error
      {:http_error, status, _} when status >= 500 -> :server_error
      {:http_error, status, _} when status >= 400 -> :client_error
      _ -> :unknown
    end
  end

  defp sanitize_error_message(error) do
    case error do
      {type, message} when is_binary(message) ->
        "#{type}: #{truncate_content(message, 200)}"
      message when is_binary(message) ->
        truncate_content(message, 200)
      _ ->
        inspect(error) |> truncate_content(200)
    end
  end

  # Message formatting for non-structured logs

  defp format_request_message(log_data) do
    "ReqLLM Request [#{log_data.correlation_id}] #{log_data.method} #{log_data.url} (#{log_data.provider})"
  end

  defp format_response_message(log_data) do
    "ReqLLM Response [#{log_data.correlation_id}] #{log_data.status} in #{log_data.duration_ms}ms (#{log_data.provider})"
  end

  defp format_streaming_message(log_data, event) do
    case event do
      :start ->
        "ReqLLM Streaming Started [#{log_data.correlation_id}] (#{log_data.provider})"
      :chunk ->
        chunk_size = get_in(log_data, [:chunk_info, :chunk_size]) || 0
        "ReqLLM Streaming Chunk [#{log_data.correlation_id}] #{chunk_size} bytes (#{log_data.provider})"
      :complete ->
        "ReqLLM Streaming Complete [#{log_data.correlation_id}] (#{log_data.provider})"
      :error ->
        error_type = get_in(log_data, [:error_info, :error_type]) || :unknown
        "ReqLLM Streaming Error [#{log_data.correlation_id}] #{error_type} (#{log_data.provider})"
      _ ->
        "ReqLLM Streaming Event [#{log_data.correlation_id}] #{event} (#{log_data.provider})"
    end
  end

  defp format_metrics_message(log_data) do
    "ReqLLM Performance Metrics [#{log_data.correlation_id}] (#{log_data.provider})"
  end
end
