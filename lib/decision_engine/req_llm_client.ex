# lib/decision_engine/req_llm_client.ex
defmodule DecisionEngine.ReqLLMClient do
  @moduledoc """
  ReqLLM client wrapper providing unified interface for LLM API interactions.

  This module implements a provider abstraction layer for OpenAI, Anthropic, and other
  LLM providers using ReqLLM as the underlying HTTP client. It provides enhanced
  capabilities including connection pooling, automatic retries, and better error handling.
  """

  require Logger
  alias DecisionEngine.ReqLLMConfigManager
  alias DecisionEngine.ReqLLMErrorHandler
  alias DecisionEngine.ReqLLMResponseValidator
  alias DecisionEngine.ReqLLMConnectionPool
  alias DecisionEngine.ReqLLMRequestBatcher
  alias DecisionEngine.ReqLLMResourceMonitor
  alias DecisionEngine.ReqLLMLogger
  alias DecisionEngine.ReqLLMCorrelation
  alias DecisionEngine.ReqLLMErrorContext

  @doc """
  Makes a non-streaming LLM API call using ReqLLM.

  ## Parameters
  - prompt: String prompt to send to the LLM
  - config: ReqLLM configuration map (optional, uses ConfigManager if nil)

  ## Returns
  - {:ok, response_content} on success
  - {:error, reason} on failure
  """
  @spec call_llm(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def call_llm(prompt, config \\ nil) do
    call_llm_with_priority(prompt, config, :normal)
  end

  @doc """
  Makes a non-streaming LLM API call with request prioritization.

  ## Parameters
  - prompt: String prompt to send to the LLM
  - config: ReqLLM configuration map (optional, uses ConfigManager if nil)
  - priority: Request priority (:high, :normal, :low) or request type atom

  ## Returns
  - {:ok, response_content} on success
  - {:error, reason} on failure
  """
  @spec call_llm_with_priority(String.t(), map() | nil, atom()) :: {:ok, String.t()} | {:error, term()}
  def call_llm_with_priority(prompt, config \\ nil, priority) do
    with {:ok, reqllm_config} <- get_reqllm_config(config),
         :ok <- ReqLLMResourceMonitor.check_resource_availability(reqllm_config.provider, priority) do

      # Generate correlation ID and request ID for tracking
      correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()
      request_id = generate_request_id()

      # Start correlation tracking
      initial_context = %{
        provider: reqllm_config.provider,
        operation: :non_streaming,
        priority: priority,
        prompt_length: String.length(prompt)
      }
      ReqLLMCorrelation.start_tracking(correlation_id, initial_context)

      # Register request start for resource monitoring
      :ok = ReqLLMResourceMonitor.register_request_start(reqllm_config.provider, request_id, priority)

      context = %{
        provider: reqllm_config.provider,
        operation: :non_streaming,
        request_id: request_id,
        correlation_id: correlation_id
      }

      # Add trace event for request start
      ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_client, :request_start, %{
        provider: reqllm_config.provider,
        priority: priority,
        batching_enabled: should_use_batching?(reqllm_config.provider, priority)
      })

      # Execute request with resource monitoring
      start_time = System.system_time(:millisecond)
      result = case should_use_batching?(reqllm_config.provider, priority) do
        true ->
          call_llm_with_batching(prompt, reqllm_config, priority, context)

        false ->
          call_llm_direct(prompt, reqllm_config, context)
      end
      end_time = System.system_time(:millisecond)

      # Register request completion and update correlation
      success = case result do
        {:ok, response} ->
          ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_client, :request_success, %{
            response_length: String.length(response),
            duration_ms: end_time - start_time
          })
          ReqLLMCorrelation.update_status(correlation_id, :completed, %{success: true})
          true
        {:error, error} ->
          ReqLLMCorrelation.add_trace_event(correlation_id, :req_llm_client, :request_error, %{
            error: inspect(error),
            duration_ms: end_time - start_time
          })
          ReqLLMCorrelation.update_status(correlation_id, :failed, %{error: error})
          false
      end
      ReqLLMResourceMonitor.register_request_completion(reqllm_config.provider, request_id, success)

      result
    else
      {:error, :system_resources_critical} ->
        Logger.warning("Request rejected due to critical system resources for #{inspect(config)}")
        {:error, "System resources are critically low. Please try again later."}

      {:error, :system_resources_degraded} ->
        Logger.warning("Low priority request rejected due to degraded system resources for #{inspect(config)}")
        {:error, "System resources are degraded. High priority requests only."}

      {:error, :max_concurrent_requests_exceeded} ->
        Logger.warning("Request rejected due to concurrent request limit for #{inspect(config)}")
        {:error, "Too many concurrent requests. Please try again later."}

      {:error, reason} ->
        Logger.error("ReqLLM configuration or resource check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Validates and normalizes a ReqLLM configuration.

  ## Parameters
  - config: Configuration map to validate

  ## Returns
  - {:ok, normalized_config} on success
  - {:error, reason} on validation failure
  """
  @spec validate_config(map()) :: {:ok, map()} | {:error, term()}
  def validate_config(config) do
    ReqLLMConfigManager.validate_reqllm_config(config)
  end

  @doc """
  Builds provider-specific configuration for ReqLLM.

  ## Parameters
  - provider: Provider atom (:openai, :anthropic, etc.)
  - settings: Provider-specific settings map

  ## Returns
  - {:ok, config} with built configuration
  - {:error, reason} if building fails
  """
  @spec build_provider_config(atom(), map()) :: {:ok, map()} | {:error, term()}
  def build_provider_config(provider, settings) do
    ReqLLMConfigManager.build_reqllm_config(provider, settings)
  end

  @doc """
  Gets provider-specific default settings.

  ## Parameters
  - provider: Provider atom

  ## Returns
  - {:ok, defaults} with default settings
  - {:error, reason} if provider not supported
  """
  @spec get_provider_defaults(atom()) :: {:ok, map()} | {:error, term()}
  def get_provider_defaults(provider) do
    ReqLLMConfigManager.get_provider_defaults(provider)
  end

  @doc """
  Initiates streaming LLM API call using ReqLLM.

  ## Parameters
  - prompt: String prompt to send to the LLM
  - config: ReqLLM configuration map
  - stream_pid: Process ID to receive streaming chunks

  ## Returns
  - {:ok, stream_ref} on successful stream initiation
  - {:error, reason} on failure
  """
  @spec stream_llm(String.t(), map(), pid()) :: {:ok, reference()} | {:error, term()}
  def stream_llm(prompt, config, stream_pid) do
    stream_llm_with_priority(prompt, config, stream_pid, :high)
  end

  @doc """
  Initiates streaming LLM API call with priority and resource monitoring.

  ## Parameters
  - prompt: String prompt to send to the LLM
  - config: ReqLLM configuration map
  - stream_pid: Process ID to receive streaming chunks
  - priority: Request priority (:high, :normal, :low)

  ## Returns
  - {:ok, stream_ref} on successful stream initiation
  - {:error, reason} on failure
  """
  @spec stream_llm_with_priority(String.t(), map(), pid(), atom()) :: {:ok, reference()} | {:error, term()}
  def stream_llm_with_priority(prompt, config, stream_pid, priority) do
    with {:ok, reqllm_config} <- get_reqllm_config(config),
         :ok <- ReqLLMResourceMonitor.check_resource_availability(reqllm_config.provider, priority) do

      # Generate correlation ID and request ID for tracking
      correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()
      request_id = generate_request_id()

      # Start correlation tracking for streaming
      initial_context = %{
        provider: reqllm_config.provider,
        operation: :streaming,
        priority: priority,
        prompt_length: String.length(prompt),
        stream_pid: stream_pid
      }
      ReqLLMCorrelation.start_tracking(correlation_id, initial_context)

      # Register request start for resource monitoring
      :ok = ReqLLMResourceMonitor.register_request_start(reqllm_config.provider, request_id, priority)

      context = %{
        provider: reqllm_config.provider,
        operation: :streaming,
        request_id: request_id,
        correlation_id: correlation_id,
        stream_pid: stream_pid
      }

      result = ReqLLMErrorHandler.with_error_handling(
        fn ->
          with {:ok, request} <- build_streaming_request(prompt, reqllm_config),
               {:ok, stream_ref} <- execute_streaming_request(request, reqllm_config, stream_pid) do
            {:ok, stream_ref}
          end
        end,
        reqllm_config,
        context
      )

      # Register completion (streaming requests complete asynchronously)
      success = case result do
        {:ok, _} -> true
        {:error, _} -> false
      end
      ReqLLMResourceMonitor.register_request_completion(reqllm_config.provider, request_id, success)

      result
    else
      {:error, reason} when reason in [:system_resources_critical, :system_resources_degraded, :max_concurrent_requests_exceeded] ->
        Logger.warning("Streaming request rejected due to resource constraints: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("ReqLLM streaming configuration failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private Functions

  defp get_reqllm_config(nil) do
    # Use ConfigManager to get current configuration
    case ReqLLMConfigManager.build_reqllm_config(:openai, %{}) do
      {:ok, config} ->
        {:ok, config}
      {:error, reason} ->
        Logger.warning("Failed to get ReqLLM config from manager: #{inspect(reason)}")
        {:error, "ReqLLM configuration not available: #{inspect(reason)}"}
    end
  end

  defp get_reqllm_config(config) when is_map(config) do
    # Validate and normalize provided config
    case ReqLLMConfigManager.normalize_config(config) do
      {:ok, normalized} ->
        case ReqLLMConfigManager.validate_reqllm_config(normalized) do
          :ok -> {:ok, normalized}
          {:error, errors} -> {:error, "Configuration validation failed: #{Enum.join(errors, ", ")}"}
        end
      {:error, reason} ->
        {:error, "Configuration normalization failed: #{reason}"}
    end
  end

  defp build_request(prompt, config) do
    case config.provider do
      :openai ->
        build_openai_request(prompt, config)
      :anthropic ->
        build_anthropic_request(prompt, config)
      :ollama ->
        build_ollama_request(prompt, config)
      :openrouter ->
        build_openrouter_request(prompt, config)
      :lm_studio ->
        build_lm_studio_request(prompt, config)
      :custom ->
        build_custom_request(prompt, config)
      _ ->
        {:error, "Unsupported provider: #{config.provider}"}
    end
  end

  defp build_openai_request(prompt, config) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config.api_key}"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that extracts structured data and provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000)
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_anthropic_request(prompt, config) do
    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    body = %{
      model: config.model,
      max_tokens: Map.get(config, :max_tokens, 2000),
      temperature: Map.get(config, :temperature, 0.7),
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ]
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_ollama_request(prompt, config) do
    headers = [
      {"content-type", "application/json"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that extracts structured data and provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      options: %{
        temperature: Map.get(config, :temperature, 0.7),
        num_predict: Map.get(config, :max_tokens, 2000)
      }
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_openrouter_request(prompt, config) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config.api_key}"},
      {"http-referer", "https://decision-engine.local"},
      {"x-title", "Decision Engine"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that extracts structured data and provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000)
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_lm_studio_request(prompt, config) do
    # LM Studio uses OpenAI-compatible API
    build_openai_request(prompt, config)
  end

  defp build_custom_request(prompt, config) do
    # Custom provider - use OpenAI-compatible format as default
    headers = [
      {"content-type", "application/json"}
    ]

    # Add API key if provided
    headers = case Map.get(config, :api_key) do
      nil -> headers
      key -> [{"authorization", "Bearer #{key}"} | headers]
    end

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that extracts structured data and provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000)
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp execute_request(request, config) do
    # Use ReqLLM with connection pooling for the actual HTTP request
    try do
      # Get or create pooled request client
      case ReqLLMConnectionPool.create_pooled_request(config.provider, config) do
        {:ok, req} ->
          # Execute request with pooled ReqLLM client
          case Req.post(req, url: request.url, json: request.body) do
            {:ok, %{status: 200, body: response_body}} ->
              {:ok, response_body}

            {:ok, %{status: status, body: body, headers: headers}} ->
              # Enhanced error handling with status and headers
              {:error, {:http_error, status, headers, body}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :pool_not_configured} ->
          # Fallback to non-pooled request if pool not configured
          Logger.warning("Connection pool not configured for #{config.provider}, using direct connection")
          execute_request_direct(request)

        {:error, reason} ->
          Logger.error("Failed to get pooled request for #{config.provider}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("ReqLLM request execution failed: #{inspect(error)}")
        {:error, error}
    end
  end

  defp execute_request_direct(request) do
    # Direct request without pooling (fallback)
    req = Req.new(
      base_url: extract_base_url(request.url),
      headers: request.headers,
      receive_timeout: request.timeout,
      retry: false  # We handle retries in ReqLLMErrorHandler
    )

    case Req.post(req, url: request.url, json: request.body) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body, headers: headers}} ->
        {:error, {:http_error, status, headers, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_base_url(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}#{if uri.port, do: ":#{uri.port}", else: ""}"
  end

  # Streaming request building
  defp build_streaming_request(prompt, config) do
    case config.provider do
      :openai ->
        build_openai_streaming_request(prompt, config)
      :anthropic ->
        build_anthropic_streaming_request(prompt, config)
      :ollama ->
        build_ollama_streaming_request(prompt, config)
      :openrouter ->
        build_openrouter_streaming_request(prompt, config)
      :lm_studio ->
        build_lm_studio_streaming_request(prompt, config)
      :custom ->
        build_custom_streaming_request(prompt, config)
      _ ->
        {:error, "Unsupported provider for streaming: #{config.provider}"}
    end
  end

  defp build_openai_streaming_request(prompt, config) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config.api_key}"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that provides architectural recommendations. Format your response using markdown for better readability."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000),
      stream: true
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_anthropic_streaming_request(prompt, config) do
    headers = [
      {"x-api-key", config.api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    body = %{
      model: config.model,
      max_tokens: Map.get(config, :max_tokens, 2000),
      temperature: Map.get(config, :temperature, 0.7),
      stream: true,
      messages: [
        %{
          role: "user",
          content: prompt
        }
      ]
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_ollama_streaming_request(prompt, config) do
    headers = [
      {"content-type", "application/json"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      stream: true,
      options: %{
        temperature: Map.get(config, :temperature, 0.7),
        num_predict: Map.get(config, :max_tokens, 2000)
      }
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_openrouter_streaming_request(prompt, config) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config.api_key}"},
      {"http-referer", "https://decision-engine.local"},
      {"x-title", "Decision Engine"}
    ]

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000),
      stream: true
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  defp build_lm_studio_streaming_request(prompt, config) do
    # LM Studio uses OpenAI-compatible API
    build_openai_streaming_request(prompt, config)
  end

  defp build_custom_streaming_request(prompt, config) do
    # Custom provider - use OpenAI-compatible format as default
    headers = [
      {"content-type", "application/json"}
    ]

    # Add API key if provided
    headers = case Map.get(config, :api_key) do
      nil -> headers
      key -> [{"authorization", "Bearer #{key}"} | headers]
    end

    body = %{
      model: config.model,
      messages: [
        %{
          role: "system",
          content: "You are a helpful assistant that provides architectural recommendations."
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      temperature: Map.get(config, :temperature, 0.7),
      max_tokens: Map.get(config, :max_tokens, 2000),
      stream: true
    }

    request = %{
      method: :post,
      url: config.base_url,
      headers: headers,
      body: body,
      timeout: Map.get(config, :timeout, 30000)
    }

    {:ok, request}
  end

  # Execute streaming request using ReqLLM
  defp execute_streaming_request(request, config, stream_pid) do
    try do
      # Build ReqLLM request for streaming
      req = Req.new(
        base_url: extract_base_url(request.url),
        headers: request.headers,
        receive_timeout: request.timeout,
        retry: false  # We handle retries in ReqLLMErrorHandler
      )

      # Generate unique stream reference
      stream_ref = make_ref()

      # Start streaming in a separate process
      streaming_pid = spawn_link(fn ->
        execute_streaming_loop(req, request, config, stream_pid, stream_ref)
      end)

      Logger.debug("Started ReqLLM streaming process: #{inspect(streaming_pid)} with ref: #{inspect(stream_ref)}")

      {:ok, stream_ref}
    rescue
      error ->
        Logger.error("ReqLLM streaming request execution failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # Streaming loop that handles the actual streaming
  defp execute_streaming_loop(req, request, config, stream_pid, stream_ref) do
    correlation_id = ReqLLMCorrelation.get_or_create_correlation_id()
    context = %{
      provider: config.provider,
      operation: :streaming,
      correlation_id: correlation_id,
      stream_ref: stream_ref
    }

    try do
      # Log streaming request
      ReqLLMLogger.log_request(request, config, context)
      ReqLLMLogger.log_streaming_event(:start, %{stream_ref: stream_ref}, context)

      case Req.post(req, url: request.url, json: request.body, into: :self) do
        {:ok, %{status: 200}} ->
          # Start receiving streaming chunks
          receive_streaming_chunks(config.provider, stream_pid, stream_ref, context)

        {:ok, %{status: status, body: body}} ->
          error = {:http_error, status, body}
          ReqLLMLogger.log_streaming_event(:error, error, context)
          send(stream_pid, {:reqllm_error, error})

        {:error, reason} ->
          ReqLLMLogger.log_streaming_event(:error, reason, context)
          send(stream_pid, {:reqllm_error, reason})
      end
    rescue
      error ->
        Logger.error("ReqLLM streaming loop error: #{inspect(error)}")
        ReqLLMLogger.log_streaming_event(:error, {:exception, error}, context)
        send(stream_pid, {:reqllm_error, {:exception, error}})
    end
  end

  # Receive and process streaming chunks
  defp receive_streaming_chunks(provider, stream_pid, stream_ref, context) do
    receive do
      {:http, _request_ref, :stream_start, _headers} ->
        Logger.debug("ReqLLM streaming started for #{provider}")
        ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_start, %{provider: provider})
        receive_streaming_chunks(provider, stream_pid, stream_ref, context)

      {:http, _request_ref, {:stream, chunk}} ->
        case parse_streaming_chunk(chunk, provider) do
          {:content, content} when byte_size(content) > 0 ->
            ReqLLMLogger.log_streaming_event(:chunk, content, context)
            ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :chunk_received, %{
              chunk_size: byte_size(content)
            })
            send(stream_pid, {:reqllm_chunk, content})
            receive_streaming_chunks(provider, stream_pid, stream_ref, context)

          :continue ->
            receive_streaming_chunks(provider, stream_pid, stream_ref, context)

          :done ->
            ReqLLMLogger.log_streaming_event(:complete, %{}, context)
            ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_complete, %{})
            send(stream_pid, {:reqllm_complete, ""})

          {:error, reason} ->
            ReqLLMLogger.log_streaming_event(:error, reason, context)
            ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_error, %{error: reason})
            send(stream_pid, {:reqllm_error, reason})
        end

      {:http, _request_ref, :stream_end} ->
        Logger.debug("ReqLLM streaming ended for #{provider}")
        ReqLLMLogger.log_streaming_event(:complete, %{}, context)
        ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_end, %{})
        send(stream_pid, {:reqllm_complete, ""})

      {:http, _request_ref, {:error, reason}} ->
        Logger.error("ReqLLM streaming error for #{provider}: #{inspect(reason)}")
        ReqLLMLogger.log_streaming_event(:error, reason, context)
        ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_error, %{error: reason})
        send(stream_pid, {:reqllm_error, reason})

    after
      30_000 ->  # 30 second timeout
        Logger.warning("ReqLLM streaming timeout for #{provider}")
        timeout_error = :timeout
        ReqLLMLogger.log_streaming_event(:error, timeout_error, context)
        ReqLLMCorrelation.add_trace_event(context.correlation_id, :req_llm_client, :stream_timeout, %{})
        send(stream_pid, {:reqllm_error, timeout_error})
    end
  end

  # Parse streaming chunks based on provider format
  defp parse_streaming_chunk(chunk, provider) do
    case provider do
      provider when provider in [:openai, :openrouter, :lm_studio, :custom] ->
        parse_openai_streaming_chunk(chunk)

      :anthropic ->
        parse_anthropic_streaming_chunk(chunk)

      :ollama ->
        parse_ollama_streaming_chunk(chunk)

      _ ->
        {:error, "Unsupported provider for chunk parsing: #{provider}"}
    end
  end

  # Parse OpenAI-format streaming chunks
  defp parse_openai_streaming_chunk(chunk) do
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        "data: [DONE]" ->
          {:halt, :done}

        <<"data: ", json_data::binary>> ->
          case Jason.decode(json_data) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) ->
              {:halt, {:content, content}}

            {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
              {:halt, :done}

            {:ok, _} ->
              {:cont, :continue}

            {:error, reason} ->
              {:halt, {:error, "Failed to parse OpenAI stream chunk: #{inspect(reason)}"}}
          end

        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Parse Anthropic streaming chunks
  defp parse_anthropic_streaming_chunk(chunk) do
    lines = String.split(chunk, "\n", trim: true)

    Enum.reduce_while(lines, :continue, fn line, _acc ->
      case line do
        <<"data: ", json_data::binary>> ->
          case Jason.decode(json_data) do
            {:ok, %{"type" => "content_block_delta", "delta" => %{"text" => content}}} when is_binary(content) ->
              {:halt, {:content, content}}

            {:ok, %{"type" => "message_stop"}} ->
              {:halt, :done}

            {:ok, _} ->
              {:cont, :continue}

            {:error, reason} ->
              {:halt, {:error, "Failed to parse Anthropic stream chunk: #{inspect(reason)}"}}
          end

        _ ->
          {:cont, :continue}
      end
    end)
  end

  # Parse Ollama streaming chunks
  defp parse_ollama_streaming_chunk(chunk) do
    case Jason.decode(chunk) do
      {:ok, %{"message" => %{"content" => content}, "done" => false}} when is_binary(content) ->
        {:content, content}

      {:ok, %{"done" => true}} ->
        :done

      {:ok, _} ->
        :continue

      {:error, reason} ->
        {:error, "Failed to parse Ollama stream chunk: #{inspect(reason)}"}
    end
  end

  # Batching and prioritization helper functions

  defp should_use_batching?(provider, priority) do
    # Check if batching is configured and beneficial for this request
    case ReqLLMRequestBatcher.get_batch_stats(provider) do
      {:ok, _stats} ->
        # Batching is configured, use it for non-high priority requests
        priority != :high

      {:error, :provider_not_configured} ->
        # Batching not configured, use direct calls
        false

      {:error, _reason} ->
        # Error getting stats, fall back to direct calls
        false
    end
  end

  defp call_llm_with_batching(prompt, config, priority, context) do
    # Create a task to wait for the batched response
    task = Task.async(fn ->
      receive do
        {:batch_response, response} -> response
      after
        30_000 -> {:error, :batch_timeout}
      end
    end)

    # Submit request to batcher
    request_data = %{
      prompt: prompt,
      config: config,
      context: context
    }

    callback = fn response ->
      send(task.pid, {:batch_response, response})
    end

    case ReqLLMRequestBatcher.submit_request(config.provider, request_data, priority, callback) do
      {:ok, _request_id} ->
        # Wait for the batched response
        case Task.await(task, 35_000) do
          {:ok, response} ->
            # Validate and normalize the response
            case ReqLLMResponseValidator.validate_and_normalize(response, config.provider, config) do
              {:ok, validated_response} ->
                {:ok, validated_response.content}
              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        # Fall back to direct call if batching fails
        Logger.warning("Batching failed for #{config.provider}, falling back to direct call: #{inspect(reason)}")
        Task.shutdown(task, :brutal_kill)
        call_llm_direct(prompt, config, context)
    end
  end

  defp call_llm_direct(prompt, config, context) do
    start_time = System.system_time(:millisecond)

    # Log request start
    request_map = case build_request(prompt, config) do
      {:ok, req} -> req
      _ -> %{method: :post, url: config.base_url}
    end
    ReqLLMLogger.log_request(request_map, config, context)

    result = ReqLLMErrorHandler.with_error_handling(
      fn ->
        with {:ok, request} <- build_request(prompt, config),
             {:ok, response} <- execute_request(request, config),
             {:ok, validated_response} <- ReqLLMResponseValidator.validate_and_normalize(response, config.provider, config) do
          {:ok, validated_response.content}
        end
      end,
      config,
      context
    )

    # Log response and handle errors
    end_time = System.system_time(:millisecond)
    duration_ms = end_time - start_time

    case result do
      {:ok, content} ->
        response_map = %{status: 200, body: content}
        ReqLLMLogger.log_response(response_map, config, context, duration_ms)
        result

      {:error, error} ->
        # Capture comprehensive error context
        ReqLLMErrorContext.capture_error_context(
          error,
          request_map,
          %{status: :error, error: error},
          config,
          context
        )
        result
    end
  end

  # Resource monitoring helper functions

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

end
